use async_trait::async_trait;
use serverpulse_core::{parse_metric_output, MetricSnapshot, ServerPulseError};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::process::{Child, Command};
use tokio::time::timeout;

pub mod known_hosts;
pub mod stream;

pub use known_hosts::{
    HostKeyChallenge, HostKeyRecord, HostKeyState, KnownHostsManager, KnownHostsPaths,
    ScannedHostKey,
};
pub use stream::{framed_sampler_script, parse_framed_text, SshStream};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshTarget {
    pub alias: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    #[serde(skip)]
    pub credential_identity: Option<String>,
    #[serde(skip)]
    pub session_credential_token: Option<String>,
    #[serde(skip)]
    pub session_credential_endpoint: Option<String>,
    #[serde(skip)]
    pub known_hosts_file: Option<PathBuf>,
    #[serde(skip)]
    pub user_known_hosts_file: Option<PathBuf>,
}

impl SshTarget {
    pub fn from_server(server: &serverpulse_core::ServerConfig) -> Self {
        Self {
            alias: server.host.clone(),
            user: server.user.clone(),
            port: server.port,
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CommandOutput {
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshResolvedTarget {
    pub alias: String,
    pub host_name: String,
    pub port: u16,
    pub user: String,
}

#[async_trait]
pub trait SshTransport: Send + Sync {
    async fn execute_short_command(
        &self,
        target: &SshTarget,
        script: &str,
    ) -> Result<CommandOutput, ServerPulseError>;

    async fn collect_once(
        &self,
        target: &SshTarget,
        script: &str,
    ) -> Result<MetricSnapshot, ServerPulseError> {
        let output = self.execute_short_command(target, script).await?;
        if output.status == Some(0) {
            return parse_metric_output(&output.stdout);
        }
        if let Ok(snapshot) = parse_metric_output(&output.stdout) {
            return Ok(snapshot);
        }
        Err(ServerPulseError::Io(std::io::Error::other(
            if output.stderr.is_empty() {
                format!("ssh exited with status {:?}", output.status)
            } else {
                output.stderr
            },
        )))
    }
}

#[derive(Debug, Clone)]
pub struct SystemOpenSsh {
    pub executable: PathBuf,
    pub timeout: Duration,
    #[cfg(test)]
    test_command_prefix: Option<Vec<String>>,
}

impl Default for SystemOpenSsh {
    fn default() -> Self {
        Self {
            executable: PathBuf::from(if cfg!(windows) { "ssh.exe" } else { "ssh" }),
            timeout: Duration::from_secs(8),
            #[cfg(test)]
            test_command_prefix: None,
        }
    }
}

impl SystemOpenSsh {
    pub fn discover_config_aliases(&self) -> Result<Vec<String>, ServerPulseError> {
        let Some(path) = default_config_path() else {
            return Ok(Vec::new());
        };
        if !path.exists() {
            return Ok(Vec::new());
        }

        let mut aliases = Vec::new();
        let mut visited = HashSet::new();
        read_config_file(&path, &mut visited, &mut aliases)?;
        Ok(aliases)
    }

    pub fn config_path() -> Option<PathBuf> {
        default_config_path()
    }

    pub fn build_arguments(&self, target: &SshTarget) -> Vec<String> {
        let batch_mode = if target.credential_identity.is_some()
            || target.session_credential_token.is_some()
        {
            "no"
        } else {
            "yes"
        };
        let mut args = vec![
            "-T".to_owned(),
            "-o".to_owned(),
            format!("BatchMode={batch_mode}"),
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.timeout.as_secs().max(1)),
            "-o".to_owned(),
            "StrictHostKeyChecking=yes".to_owned(),
            "-o".to_owned(),
            "NumberOfPasswordPrompts=1".to_owned(),
        ];
        if let Some(path) = &target.known_hosts_file {
            args.push("-o".to_owned());
            args.push(format!("UserKnownHostsFile={}", path.to_string_lossy()));
        }
        if let Some(path) = &target.user_known_hosts_file {
            args.push("-o".to_owned());
            args.push(format!("GlobalKnownHostsFile={}", path.to_string_lossy()));
        }
        if let Some(port) = target.port {
            args.push("-p".to_owned());
            args.push(port.to_string());
        }
        // End options before the destination. This keeps aliases beginning with
        // a dash from being interpreted as OpenSSH flags and matches `ssh -G`.
        args.push("--".to_owned());
        if let Some(user) = &target.user {
            args.push(format!("{}@{}", user, target.alias));
        } else {
            args.push(target.alias.clone());
        }
        args.push("sh".to_owned());
        args.push("-s".to_owned());
        args
    }

    fn configure_process(command: &mut Command) {
        command.kill_on_drop(true);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        #[cfg(windows)]
        {
            // Keep ssh.exe and the askpass helper from opening a console when
            // the desktop application is launched from Explorer.
            command.creation_flags(0x0800_0000 | 0x0000_0200);
        }
    }

    pub(crate) async fn spawn_command(&self, target: &SshTarget) -> Result<Child, ServerPulseError> {
        let mut command = Command::new(&self.executable);
        #[cfg(test)]
        if let Some(prefix) = &self.test_command_prefix {
            command.args(prefix);
        }
        command.args(self.build_arguments(target));
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        if target.credential_identity.is_some() || target.session_credential_token.is_some() {
            // The password is fetched by the askpass child from the OS
            // credential store or a one-time local IPC endpoint. Only an
            // identity or random token crosses the process boundary.
            command.env("SSH_ASKPASS", std::env::current_exe().map_err(ServerPulseError::Io)?);
            command.env("SSH_ASKPASS_REQUIRE", "force");
            if let Some(identity) = &target.credential_identity {
                command.env("SERVERPULSE_CREDENTIAL_ID", identity);
            }
            if let Some(token) = &target.session_credential_token {
                command.env("SERVERPULSE_SESSION_TOKEN", token);
            }
            if let Some(endpoint) = &target.session_credential_endpoint {
                command.env("SERVERPULSE_SESSION_ENDPOINT", endpoint);
            }
        }
        Self::configure_process(&mut command);
        command.spawn().map_err(ServerPulseError::Io)
    }

    pub async fn execute_short_command_with_timeout(
        &self,
        target: &SshTarget,
        script: &str,
        command_timeout: Duration,
    ) -> Result<CommandOutput, ServerPulseError> {
        let mut child = self.spawn_command(target).await?;
        if let Some(mut stdin) = child.stdin.take() {
            let clean = script.replace("\r\n", "\n").replace('\r', "");
            stdin.write_all(clean.as_bytes()).await?;
            stdin.flush().await?;
            drop(stdin);
        }
        let output = timeout(command_timeout, child.wait_with_output())
            .await
            .map_err(|_| ServerPulseError::Timeout("SSH command timed out".to_owned()))?
            .map_err(ServerPulseError::Io)?;
        Ok(CommandOutput {
            status: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    pub async fn resolve_config(&self, alias: &str) -> Result<SshResolvedTarget, ServerPulseError> {
        let mut command = Command::new(&self.executable);
        command.args(["-G", "--", alias]);
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        Self::configure_process(&mut command);
        let output = timeout(self.timeout, command.output())
            .await
            .map_err(|_| ServerPulseError::Timeout("ssh -G timed out".to_owned()))?
            .map_err(ServerPulseError::Io)?;
        if !output.status.success() {
            return Err(ServerPulseError::Authentication(
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ));
        }
        let mut user = None;
        let mut hostname = alias.to_owned();
        let mut port = 22u16;
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let mut parts = line.split_whitespace();
            match parts.next() {
                Some("user") => user = parts.next().map(str::to_owned),
                Some("hostname") => {
                    if let Some(h) = parts.next() {
                        hostname = h.to_owned();
                    }
                }
                Some("port") => {
                    if let Some(p) = parts.next().and_then(|value| value.parse().ok()) {
                        port = p;
                    }
                }
                _ => {}
            }
        }
        let user = user.unwrap_or_else(|| {
            std::env::var("USERNAME")
                .or_else(|_| std::env::var("USER"))
                .unwrap_or_else(|_| "default".to_owned())
        });
        Ok(SshResolvedTarget {
            alias: alias.to_owned(),
            host_name: hostname,
            port,
            user,
        })
    }
}

fn default_config_path() -> Option<PathBuf> {
    let home = home_directory()?;
    Some(home.join(".ssh").join("config"))
}

fn home_directory() -> Option<PathBuf> {
    dirs::home_dir().or_else(|| {
        if cfg!(windows) {
            std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .or_else(|| {
                    let drive = std::env::var_os("HOMEDRIVE")?;
                    let path = std::env::var_os("HOMEPATH")?;
                    Some(format!("{}{}", drive.to_string_lossy(), path.to_string_lossy()).into())
                })
                .map(PathBuf::from)
        } else {
            std::env::var_os("HOME").map(PathBuf::from)
        }
    })
}

fn read_config_file(
    path: &Path,
    visited: &mut HashSet<PathBuf>,
    aliases: &mut Vec<String>,
) -> Result<(), ServerPulseError> {
    let identity = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if !visited.insert(identity) {
        return Ok(());
    }
    let bytes = fs::read(path)?;
    let text = decode_config_text(&bytes);
    let base = path.parent().unwrap_or_else(|| Path::new("."));
    for raw_line in text.lines() {
        let line = raw_line.split('#').next().unwrap_or_default().trim();
        if line.is_empty() {
            continue;
        }
        let (directive, rest) = if let Some((dir, args)) = line.split_once('=') {
            let dir = dir.trim();
            if dir.contains(char::is_whitespace) {
                line.split_once(char::is_whitespace).unwrap_or((line, ""))
            } else {
                (dir, args)
            }
        } else {
            line.split_once(char::is_whitespace).unwrap_or((line, ""))
        };

        if directive.eq_ignore_ascii_case("host") {
            for pattern in rest.split(|c: char| c.is_whitespace() || c == ',') {
                let pattern = pattern.trim_matches(['"', '\'']).trim();
                if is_literal_alias(pattern) && !aliases.iter().any(|value| value.eq_ignore_ascii_case(pattern)) {
                    aliases.push(pattern.to_owned());
                }
            }
        } else if directive.eq_ignore_ascii_case("include") {
            for include in rest.split(|c: char| c.is_whitespace() || c == ',') {
                let include = include.trim_matches(['"', '\'']).trim();
                if include.is_empty() || include == "=" {
                    continue;
                }
                for candidate in expand_include_path(include, base) {
                    if candidate.is_file() {
                        read_config_file(&candidate, visited, aliases)?;
                    }
                }
            }
        }
    }
    Ok(())
}

fn decode_config_text(bytes: &[u8]) -> String {
    if let Some(bytes) = bytes.strip_prefix(&[0xff, 0xfe]) {
        let units = bytes
            .chunks_exact(2)
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16_lossy(&units);
    }
    if let Some(bytes) = bytes.strip_prefix(&[0xfe, 0xff]) {
        let units = bytes
            .chunks_exact(2)
            .map(|chunk| u16::from_be_bytes([chunk[0], chunk[1]]))
            .collect::<Vec<_>>();
        return String::from_utf16_lossy(&units);
    }
    String::from_utf8_lossy(bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes)).into_owned()
}

fn expand_include_path(value: &str, base: &Path) -> Vec<PathBuf> {
    let mut resolved_str = value.to_owned();
    if cfg!(windows) && resolved_str.contains('%') {
        for (key, val) in std::env::vars() {
            let placeholder = format!("%{}%", key);
            if resolved_str.contains(&placeholder) {
                resolved_str = resolved_str.replace(&placeholder, &val);
            }
        }
    }

    let home = home_directory();
    let value_path = if resolved_str == "~" {
        home.unwrap_or_else(|| PathBuf::from(&resolved_str))
    } else if let Some(rest) = resolved_str.strip_prefix("~/").or_else(|| resolved_str.strip_prefix("~\\")) {
        home.map(|h| h.join(rest)).unwrap_or_else(|| PathBuf::from(&resolved_str))
    } else {
        let p = PathBuf::from(&resolved_str);
        if p.is_absolute() {
            p
        } else {
            base.join(p)
        }
    };

    if !value_path.to_string_lossy().contains(['*', '?']) {
        return vec![value_path];
    }
    let Some(parent) = value_path.parent() else {
        return Vec::new();
    };
    let Some(file_pattern) = value_path.file_name().and_then(|name| name.to_str()) else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(parent) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name();
            let name = name.to_str()?;
            wildcard_match(file_pattern, name).then_some(entry.path())
        })
        .collect()
}

fn wildcard_match(pattern: &str, value: &str) -> bool {
    let pattern = pattern.as_bytes();
    let value = value.as_bytes();
    let mut p = 0;
    let mut v = 0;
    let mut star = None;
    let mut mark = 0;
    while v < value.len() {
        if p < pattern.len() && (pattern[p] == value[v] || pattern[p] == b'?') {
            p += 1;
            v += 1;
        } else if p < pattern.len() && pattern[p] == b'*' {
            star = Some(p);
            p += 1;
            mark = v;
        } else if let Some(star) = star {
            p = star + 1;
            mark += 1;
            v = mark;
        } else {
            return false;
        }
    }
    while p < pattern.len() && pattern[p] == b'*' {
        p += 1;
    }
    p == pattern.len()
}

fn is_literal_alias(value: &str) -> bool {
    !value.is_empty()
        && !value.contains(['*', '?', '!'])
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
}

#[async_trait]
impl SshTransport for SystemOpenSsh {
    async fn execute_short_command(
        &self,
        target: &SshTarget,
        script: &str,
    ) -> Result<CommandOutput, ServerPulseError> {
        self.execute_short_command_with_timeout(
            target,
            script,
            self.timeout.saturating_add(Duration::from_secs(4)),
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_safe_batch_arguments() {
        let ssh = SystemOpenSsh::default();
        let target = SshTarget {
            alias: "3090".to_owned(),
            user: Some("alice".to_owned()),
            port: Some(2222),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
        };
        assert_eq!(
            ssh.build_arguments(&target),
            vec![
                "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=yes", "-o", "NumberOfPasswordPrompts=1",
                "-p", "2222", "--", "alice@3090", "sh", "-s"
            ]
        );
    }

    #[test]
    fn never_places_password_in_arguments() {
        let ssh = SystemOpenSsh::default();
        let target = SshTarget {
            alias: "server".to_owned(),
            user: Some("alice".to_owned()),
            port: None,
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
        };
        let args = ssh.build_arguments(&target).join(" ");
        assert!(!args.contains("password"));
    }

    #[test]
    fn saved_credential_mode_only_changes_batch_policy() {
        let ssh = SystemOpenSsh::default();
        let target = SshTarget {
            alias: "server".to_owned(),
            user: Some("alice".to_owned()),
            port: None,
            credential_identity: Some("alice@server:22".to_owned()),
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
        };
        let args = ssh.build_arguments(&target).join(" ");
        assert!(args.contains("BatchMode=no"));
        assert!(args.contains("alice@server"));
        assert!(!args.contains("alice@server:22"));
    }

    #[test]
    fn known_hosts_arguments_are_explicit_and_password_free() {
        let ssh = SystemOpenSsh::default();
        let target = SshTarget {
            alias: "server".to_owned(),
            user: None,
            port: Some(2222),
            credential_identity: None,
            session_credential_token: Some("random-token".to_owned()),
            session_credential_endpoint: Some(r"\\.\pipe\serverpulse-askpass-random".to_owned()),
            known_hosts_file: Some(PathBuf::from(r"C:\ServerPulse\known_hosts")),
            user_known_hosts_file: Some(PathBuf::from(r"C:\Users\alice\.ssh\known_hosts")),
        };
        let args = ssh.build_arguments(&target).join(" ");
        assert!(args.contains("StrictHostKeyChecking=yes"));
        assert!(args.contains(r"UserKnownHostsFile=C:\ServerPulse\known_hosts"));
        assert!(args.contains(r"GlobalKnownHostsFile=C:\Users\alice\.ssh\known_hosts"));
        assert!(!args.contains("random-password"));
    }

    #[test]
    fn discovers_literal_host_aliases_and_skips_patterns() {
        let mut aliases = Vec::new();
        let mut visited = HashSet::new();
        let root = std::env::temp_dir().join("serverpulse-ssh-config-test");
        fs::create_dir_all(&root).expect("config root");
        let path = root.join("config");
        fs::write(
            &path,
            "Host *\n  User default\nHost gpu-01 gpu-02\nHost = gpu-03\nHost \"gpu-04\", 'gpu-05'\nHost !excluded *-backup\n",
        )
        .expect("config file");
        read_config_file(&path, &mut visited, &mut aliases).expect("read config");
        assert_eq!(aliases, vec!["gpu-01", "gpu-02", "gpu-03", "gpu-04", "gpu-05"]);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn expands_simple_include_globs() {
        let root = std::env::temp_dir().join("serverpulse-ssh-include-test");
        fs::create_dir_all(root.join("conf.d")).expect("config root");
        fs::write(root.join("conf.d/one"), "Host one\n").expect("include one");
        fs::write(root.join("conf.d/two"), "Host two\n").expect("include two");
        let matches = expand_include_path("conf.d/*", &root);
        assert_eq!(matches.len(), 2);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn decodes_utf16_and_bom_config_text() {
        assert_eq!(decode_config_text(&[0xff, 0xfe, b'H', 0, b'i', 0]), "Hi");
        assert_eq!(decode_config_text(&[0xef, 0xbb, 0xbf, b'H', b'i']), "Hi");
    }

    #[test]
    fn resolves_home_tilde_in_include_path() {
        let home = home_directory().unwrap_or_else(|| PathBuf::from("."));
        let base = home.join(".ssh");
        let expanded = expand_include_path("~/.ssh/config", &base);
        assert_eq!(expanded.len(), 1);
        assert_eq!(expanded[0], home.join(".ssh").join("config"));
    }

    fn test_target() -> SshTarget {
        SshTarget {
            alias: "test-target".to_owned(),
            user: None,
            port: None,
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
        }
    }

    #[cfg(windows)]
    fn delayed_command_prefix() -> Vec<String> {
        vec![
            "/D".to_owned(),
            "/C".to_owned(),
            "ping -n 6 127.0.0.1 > nul & exit /b 0".to_owned(),
        ]
    }

    #[cfg(unix)]
    fn delayed_command_prefix() -> Vec<String> {
        vec!["-c".to_owned(), "sleep 5".to_owned()]
    }

    #[tokio::test]
    async fn slow_bulk_command_accepts_explicit_operation_timeout() {
        let ssh = SystemOpenSsh {
            executable: PathBuf::from(if cfg!(windows) { "cmd.exe" } else { "sh" }),
            timeout: Duration::from_millis(50),
            test_command_prefix: Some(delayed_command_prefix()),
        };

        let result = ssh
            .execute_short_command_with_timeout(
                &test_target(),
                "echo pull",
                Duration::from_secs(8),
            )
            .await
            .expect("bulk operation should use its explicit deadline");
        assert_eq!(result.status, Some(0));
    }

    #[test]
    #[ignore]
    fn test_live_ssh() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let ssh = SystemOpenSsh::default();
            let target = SshTarget {
                alias: "3090".to_owned(),
                user: Some("test-user".to_owned()),
                port: Some(22),
                credential_identity: None,
                session_credential_token: None,
                session_credential_endpoint: None,
                known_hosts_file: None,
                user_known_hosts_file: None,
            };
            let script = include_str!("../../../../assets/serverpulse-sample.sh");
            let res = ssh.collect_once(&target, script).await;
            println!("LIVE SSH COLLECT RESULT: {:?}", res);
            assert!(res.is_ok(), "Collect failed: {:?}", res);
        });
    }
}
