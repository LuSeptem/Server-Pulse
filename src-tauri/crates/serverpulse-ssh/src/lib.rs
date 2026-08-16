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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SshTarget {
    pub alias: String,
    pub user: Option<String>,
    pub port: Option<u16>,
    #[serde(skip)]
    pub credential_identity: Option<String>,
}

impl SshTarget {
    pub fn from_server(server: &serverpulse_core::ServerConfig) -> Self {
        Self {
            alias: server.host.clone(),
            user: server.user.clone(),
            port: server.port,
            credential_identity: None,
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
        if output.status != Some(0) {
            return Err(ServerPulseError::Io(std::io::Error::other(
                if output.stderr.is_empty() {
                    "ssh exited with a failure status".to_owned()
                } else {
                    output.stderr
                },
            )));
        }
        parse_metric_output(&output.stdout)
    }
}

#[derive(Debug, Clone)]
pub struct SystemOpenSsh {
    pub executable: PathBuf,
    pub timeout: Duration,
}

impl Default for SystemOpenSsh {
    fn default() -> Self {
        Self {
            executable: PathBuf::from(if cfg!(windows) { "ssh.exe" } else { "ssh" }),
            timeout: Duration::from_secs(8),
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
        let batch_mode = if target.credential_identity.is_some() { "no" } else { "yes" };
        let mut args = vec![
            "-o".to_owned(),
            format!("BatchMode={batch_mode}"),
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.timeout.as_secs().max(1)),
            "-o".to_owned(),
            "StrictHostKeyChecking=yes".to_owned(),
        ];
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

    async fn spawn_command(&self, target: &SshTarget) -> Result<Child, ServerPulseError> {
        let mut command = Command::new(&self.executable);
        command.args(self.build_arguments(target));
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        if let Some(identity) = &target.credential_identity {
            // The password is fetched by the askpass child from the OS
            // credential store. Only the non-secret identity crosses the
            // process boundary.
            command.env("SSH_ASKPASS", std::env::current_exe().map_err(ServerPulseError::Io)?);
            command.env("SSH_ASKPASS_REQUIRE", "force");
            command.env("SERVERPULSE_CREDENTIAL_ID", identity);
        }
        Self::configure_process(&mut command);
        command.spawn().map_err(ServerPulseError::Io)
    }

    pub async fn resolve_config(&self, alias: &str) -> Result<SshTarget, ServerPulseError> {
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
        let mut port = None;
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let mut parts = line.split_whitespace();
            match parts.next() {
                Some("user") => user = parts.next().map(str::to_owned),
                Some("hostname") => hostname = parts.next().unwrap_or(alias).to_owned(),
                Some("port") => port = parts.next().and_then(|value| value.parse().ok()),
                _ => {}
            }
        }
        Ok(SshTarget {
            alias: hostname,
            user,
            port,
            credential_identity: None,
        })
    }
}

fn default_config_path() -> Option<PathBuf> {
    let home = home_directory()?;
    Some(home.join(".ssh").join("config"))
}

fn home_directory() -> Option<PathBuf> {
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
        let mut fields = line.split_whitespace();
        let Some(directive) = fields.next() else {
            continue;
        };
        if directive.eq_ignore_ascii_case("host") {
            for pattern in fields {
                let pattern = pattern.trim_matches(['"', '\'']);
                if is_literal_alias(pattern) && !aliases.iter().any(|value| value == pattern) {
                    aliases.push(pattern.to_owned());
                }
            }
        } else if directive.eq_ignore_ascii_case("include") {
            for include in fields {
                let include = include.trim_matches(['"', '\'']);
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
    let value = if value == "~" {
        default_config_path()
            .and_then(|path| path.parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from(value))
    } else if let Some(rest) = value.strip_prefix("~/") {
        default_config_path()
            .and_then(|path| path.parent().map(|parent| parent.join(rest)))
            .unwrap_or_else(|| PathBuf::from(value))
    } else {
        let path = PathBuf::from(value);
        if path.is_absolute() {
            path
        } else {
            base.join(path)
        }
    };

    if !value.to_string_lossy().contains(['*', '?']) {
        return vec![value];
    }
    let Some(parent) = value.parent() else {
        return Vec::new();
    };
    let Some(file_pattern) = value.file_name().and_then(|name| name.to_str()) else {
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
        let mut child = self.spawn_command(target).await?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(script.replace("\r\n", "\n").as_bytes()).await?;
        }
        let output = timeout(self.timeout + Duration::from_secs(2), child.wait_with_output())
            .await
            .map_err(|_| ServerPulseError::Timeout("SSH command timed out".to_owned()))?
            .map_err(ServerPulseError::Io)?;
        Ok(CommandOutput {
            status: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
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
        };
        assert_eq!(
            ssh.build_arguments(&target),
            vec![
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=yes", "-p", "2222", "--", "alice@3090"
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
        };
        let args = ssh.build_arguments(&target).join(" ");
        assert!(args.contains("BatchMode=no"));
        assert!(args.contains("alice@server"));
        assert!(!args.contains("alice@server:22"));
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
            "Host *\n  User default\nHost gpu-01 gpu-02\nHost !excluded *-backup\n",
        )
        .expect("config file");
        read_config_file(&path, &mut visited, &mut aliases).expect("read config");
        assert_eq!(aliases, vec!["gpu-01", "gpu-02"]);
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
}
