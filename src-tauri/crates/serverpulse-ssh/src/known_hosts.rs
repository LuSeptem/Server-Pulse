use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;
use tokio::time::timeout;

use crate::{append_config_argument, configure_process, existing_config_path, SshTarget};
use serverpulse_core::ServerPulseError;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HostKeyState {
    Unknown,
    Trusted,
    Changed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HostKeyRecord {
    pub algorithm: String,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct HostKeyChallenge {
    pub challenge_id: String,
    pub server: String,
    pub port: u16,
    pub keys: Vec<HostKeyRecord>,
    pub state: HostKeyState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScannedHostKey {
    pub host: String,
    pub algorithm: String,
    pub key: String,
    pub fingerprint: String,
    pub line: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownHostsPaths {
    pub application: PathBuf,
    pub user: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct KnownHostsManager {
    pub paths: KnownHostsPaths,
    pub scan_executable: PathBuf,
    pub ssh_executable: PathBuf,
    pub timeout: Duration,
}

impl KnownHostsManager {
    pub fn new(application: impl Into<PathBuf>, user: Option<PathBuf>) -> Self {
        Self {
            paths: KnownHostsPaths {
                application: application.into(),
                user,
            },
            scan_executable: PathBuf::from(if cfg!(windows) {
                "ssh-keyscan.exe"
            } else {
                "ssh-keyscan"
            }),
            ssh_executable: PathBuf::from(if cfg!(windows) { "ssh.exe" } else { "ssh" }),
            timeout: Duration::from_secs(8),
        }
    }

    pub fn user_known_hosts_path() -> Option<PathBuf> {
        crate::home_directory().map(|home| home.join(".ssh").join("known_hosts"))
    }

    pub async fn probe(
        &self,
        target: &SshTarget,
        challenge_id: String,
    ) -> Result<HostKeyChallenge, ServerPulseError> {
        let scan = self.scan(target).await?;
        let state = self.classify(target, &scan)?;
        Ok(HostKeyChallenge {
            challenge_id,
            server: target.alias.clone(),
            port: target.port.unwrap_or(22),
            keys: scan
                .iter()
                .map(|key| HostKeyRecord {
                    algorithm: key.algorithm.clone(),
                    fingerprint: key.fingerprint.clone(),
                })
                .collect(),
            state,
        })
    }

    pub async fn scan(&self, target: &SshTarget) -> Result<Vec<ScannedHostKey>, ServerPulseError> {
        let mut command = Command::new(&self.scan_executable);
        command.args(self.scan_arguments(target));
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        configure_process(&mut command);
        let output = timeout(self.timeout, command.output())
            .await
            .map_err(|_| ServerPulseError::Timeout("ssh-keyscan timed out".to_owned()))?
            .map_err(ServerPulseError::Io)?;
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        if cfg!(windows)
            && (should_fallback_to_ssh_probe(&stdout) || should_fallback_to_ssh_probe(&stderr))
        {
            return self.scan_with_ssh(target).await;
        }
        if !output.status.success() && output.stdout.is_empty() {
            return Err(ServerPulseError::Authentication(
                stderr.trim().to_owned(),
            ));
        }
        let keys = parse_scan_output(&stdout)?;
        if keys.is_empty() {
            return Err(ServerPulseError::Authentication(
                "ssh-keyscan returned no host keys".to_owned(),
            ));
        }
        Ok(keys)
    }

    async fn scan_with_ssh(
        &self,
        target: &SshTarget,
    ) -> Result<Vec<ScannedHostKey>, ServerPulseError> {
        let temporary_path = temporary_probe_path();
        let result = async {
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary_path)?;

            let mut command = Command::new(&self.ssh_executable);
            command.args(self.ssh_probe_arguments(target, &temporary_path));
            command.stdout(Stdio::piped());
            command.stderr(Stdio::piped());
            configure_process(&mut command);
            let output = timeout(self.timeout, command.output())
                .await
                .map_err(|_| ServerPulseError::Timeout("SSH host-key probe timed out".to_owned()))?
                .map_err(ServerPulseError::Io)?;
            let text = fs::read_to_string(&temporary_path)?;
            let keys = parse_scan_output(&text)?;
            if !keys.is_empty() {
                return Ok(keys);
            }

            let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            Err(ServerPulseError::Authentication(if detail.is_empty() {
                "SSH host-key probe returned no host keys".to_owned()
            } else {
                detail
            }))
        }
        .await;
        let _ = fs::remove_file(&temporary_path);
        result
    }

    fn ssh_probe_arguments(&self, target: &SshTarget, known_hosts: &Path) -> Vec<String> {
        self.ssh_probe_arguments_with_config(target, known_hosts, existing_config_path().as_deref())
    }

    fn ssh_probe_arguments_with_config(
        &self,
        target: &SshTarget,
        known_hosts: &Path,
        config_file: Option<&Path>,
    ) -> Vec<String> {
        let null_known_hosts = if cfg!(windows) { "NUL" } else { "/dev/null" };
        let mut args = Vec::new();
        append_config_argument(&mut args, config_file);
        args.extend([
            "-T".to_owned(),
            "-o".to_owned(),
            format!("ConnectTimeout={}", self.timeout.as_secs().max(1)),
            "-o".to_owned(),
            format!("UserKnownHostsFile={}", known_hosts.to_string_lossy()),
            "-o".to_owned(),
            format!("GlobalKnownHostsFile={null_known_hosts}"),
            "-o".to_owned(),
            "StrictHostKeyChecking=accept-new".to_owned(),
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            "-o".to_owned(),
            "PreferredAuthentications=none".to_owned(),
        ]);
        if let Some(port) = target.resolved_port.or(target.port) {
            args.push("-p".to_owned());
            args.push(port.to_string());
        }
        args.push("--".to_owned());
        if let Some(user) = &target.user {
            args.push(format!("{user}@{}", target.alias));
        } else {
            args.push(target.alias.clone());
        }
        args.push("exit".to_owned());
        args
    }

    fn scan_arguments(&self, target: &SshTarget) -> Vec<String> {
        let mut args = vec!["-T".to_owned(), "5".to_owned()];
        if let Some(port) = target.resolved_port.or(target.port) {
            args.push("-p".to_owned());
            args.push(port.to_string());
        }
        args.extend([
            "-t".to_owned(),
            "rsa,ecdsa,ed25519".to_owned(),
            "--".to_owned(),
            target
                .resolved_host
                .as_deref()
                .unwrap_or(&target.alias)
                .to_owned(),
        ]);
        args
    }

    pub fn classify(
        &self,
        target: &SshTarget,
        scanned: &[ScannedHostKey],
    ) -> Result<HostKeyState, ServerPulseError> {
        if scanned.is_empty() {
            return Err(ServerPulseError::InvalidConfig(
                "host key probe returned no keys".to_owned(),
            ));
        }
        let app_text = read_optional(&self.paths.application)?.unwrap_or_default();
        let user_text = self
            .paths
            .user
            .as_deref()
            .map(read_optional)
            .transpose()?
            .flatten()
            .unwrap_or_default();
        let host_names = host_names(target);
        let app_keys = matching_keys(&app_text, &host_names);
        let user_keys = matching_keys(&user_text, &host_names);
        if scanned
            .iter()
            .any(|key| app_keys.iter().any(|candidate| candidate == &key.fingerprint))
        {
            return Ok(HostKeyState::Trusted);
        }
        // Once the application has recorded a key, it is authoritative. A
        // newer user-file key must not bypass a changed-key block.
        if !app_keys.is_empty() {
            return Ok(HostKeyState::Changed);
        }
        if scanned
            .iter()
            .any(|key| user_keys.iter().any(|candidate| candidate == &key.fingerprint))
        {
            return Ok(HostKeyState::Trusted);
        }
        if !user_keys.is_empty() {
            Ok(HostKeyState::Changed)
        } else {
            Ok(HostKeyState::Unknown)
        }
    }

    pub fn accept(
        &self,
        target: &SshTarget,
        scanned: &[ScannedHostKey],
    ) -> Result<(), ServerPulseError> {
        let state = self.classify(target, scanned)?;
        if state == HostKeyState::Changed {
            return Err(ServerPulseError::Authentication(
                "host key changed; forget the application key before re-verifying".to_owned(),
            ));
        }
        if state == HostKeyState::Trusted {
            return Ok(());
        }
        if let Some(parent) = self.paths.application.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.paths.application)?;
        for key in scanned {
            writeln!(file, "{}", key.line.trim())?;
        }
        file.sync_all()?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&self.paths.application, fs::Permissions::from_mode(0o600))?;
        }
        Ok(())
    }

    pub fn forget(&self, target: &SshTarget) -> Result<(), ServerPulseError> {
        let path = &self.paths.application;
        if !path.exists() {
            return Ok(());
        }
        let text = fs::read_to_string(path)?;
        let names = host_names(target);
        let retained = text
            .lines()
            .filter(|line| {
                let clean = line.trim();
                clean.is_empty()
                    || clean.starts_with('#')
                    || !line_matches_host(clean, &names)
            })
            .collect::<Vec<_>>();
        let mut output = retained.join("\n");
        if !output.is_empty() {
            output.push('\n');
        }
        fs::write(path, output)?;
        Ok(())
    }
}

fn should_fallback_to_ssh_probe(output: &str) -> bool {
    output
        .to_ascii_lowercase()
        .contains("choose_kex: unsupported kex method")
}

fn temporary_probe_path() -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "serverpulse-hostkey-{}-{nanos}.known_hosts",
        std::process::id()
    ))
}

pub fn parse_scan_output(text: &str) -> Result<Vec<ScannedHostKey>, ServerPulseError> {
    let mut keys = Vec::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let parts = line.split_whitespace().collect::<Vec<_>>();
        if parts.len() < 3 || parts[1].starts_with("SSH-2.0") {
            continue;
        }
        let decoded = STANDARD.decode(parts[2]).map_err(|_| {
            ServerPulseError::InvalidConfig("ssh-keyscan returned an invalid key".to_owned())
        })?;
        let digest = Sha256::digest(decoded);
        let fingerprint = format!(
            "SHA256:{}",
            base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)
        );
        keys.push(ScannedHostKey {
            host: parts[0].to_owned(),
            algorithm: parts[1].to_owned(),
            key: parts[2].to_owned(),
            fingerprint,
            line: line.to_owned(),
        });
    }
    Ok(keys)
}

fn read_optional(path: &Path) -> Result<Option<String>, ServerPulseError> {
    if path.exists() {
        Ok(Some(fs::read_to_string(path)?))
    } else {
        Ok(None)
    }
}

fn host_names(target: &SshTarget) -> Vec<String> {
    let port = target.resolved_port.or(target.port).unwrap_or(22);
    let mut names = vec![target.alias.clone(), format!("[{0}]:{1}", target.alias, port)];
    if let Some(resolved_host) = target.resolved_host.as_deref() {
        if !resolved_host.eq_ignore_ascii_case(&target.alias) {
            names.push(resolved_host.to_owned());
            names.push(format!("[{resolved_host}]:{port}"));
        }
    }
    if port == 22 {
        names.push(format!("[{0}]:22", target.alias));
        if let Some(resolved_host) = target.resolved_host.as_deref() {
            names.push(format!("[{resolved_host}]:22"));
        }
    }
    names
}

fn matching_keys(text: &str, names: &[String]) -> Vec<String> {
    text.lines()
        .filter_map(|line| parse_known_host_line(line, names))
        .collect()
}

fn parse_known_host_line(line: &str, names: &[String]) -> Option<String> {
    let clean = line.trim();
    if clean.is_empty() || clean.starts_with('#') {
        return None;
    }
    let parts = clean.split_whitespace().collect::<Vec<_>>();
    if parts.len() < 3 {
        return None;
    }
    let host_match = host_field_matches(parts[0], names);
    if !host_match {
        return None;
    }
    let decoded = STANDARD.decode(parts[2]).ok()?;
    let digest = Sha256::digest(decoded);
    Some(format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)
    ))
}

fn line_matches_host(line: &str, names: &[String]) -> bool {
    let Some(hosts) = line.split_whitespace().next() else {
        return false;
    };
    host_field_matches(hosts, names)
}

fn host_field_matches(field: &str, names: &[String]) -> bool {
    field.split(',').any(|candidate| {
        if let Some(encoded) = candidate.strip_prefix("|1|") {
            let mut parts = encoded.split('|');
            let Some(salt) = parts.next().and_then(|value| STANDARD.decode(value).ok()) else {
                return false;
            };
            let Some(expected) = parts.next().and_then(|value| STANDARD.decode(value).ok()) else {
                return false;
            };
            return names.iter().any(|name| {
                let Ok(mut mac) = Hmac::<Sha1>::new_from_slice(&salt) else {
                    return false;
                };
                mac.update(name.as_bytes());
                mac.verify_slice(&expected).is_ok()
            });
        }
        names
            .iter()
            .any(|name| candidate.eq_ignore_ascii_case(name))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_paths() -> (PathBuf, PathBuf) {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!("serverpulse-known-hosts-{suffix}"));
        fs::create_dir_all(&root).expect("temp root");
        (root.join("app-known_hosts"), root.join("user-known_hosts"))
    }

    #[test]
    fn computes_openssh_sha256_fingerprint() {
        let scan = parse_scan_output("example ssh-ed25519 AQID\n")
            .expect("scan");
        assert_eq!(scan.len(), 1);
        assert_eq!(scan[0].fingerprint, "SHA256:A5BYxvLAy0ksUzsKTRTvd8wPeKvMztUofYShogEc+4E");
    }

    #[test]
    fn scans_resolved_ssh_config_host_and_port() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "gpu-alias".to_owned(),
            user: None,
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: Some("10.0.0.7".to_owned()),
            resolved_port: Some(2200),
        };
        let manager = KnownHostsManager::new(&app, Some(user));
        assert_eq!(
            manager.scan_arguments(&target),
            vec![
                "-T".to_owned(),
                "5".to_owned(),
                "-p".to_owned(),
                "2200".to_owned(),
                "-t".to_owned(),
                "rsa,ecdsa,ed25519".to_owned(),
                "--".to_owned(),
                "10.0.0.7".to_owned(),
            ]
        );
        let _ = fs::remove_file(app);
    }

    #[test]
    fn ssh_probe_arguments_include_explicit_user_config() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "gpu-alias".to_owned(),
            user: Some("alice".to_owned()),
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: None,
            resolved_port: None,
        };
        let manager = KnownHostsManager::new(&app, Some(user));
        let config = PathBuf::from(r"C:\Users\alice\.ssh\config");
        let args = manager.ssh_probe_arguments_with_config(&target, &app, Some(&config));
        assert!(args
            .windows(2)
            .any(|pair| pair[0] == "-F" && pair[1] == r"C:\Users\alice\.ssh\config"));
        let _ = fs::remove_file(app);
    }

    #[test]
    fn falls_back_when_windows_keyscan_cannot_handle_sntrup_kex() {
        let stderr = "# 10.0.0.7:22 SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.16\\nchoose_kex: unsupported KEX method sntrup761x25519-sha512@openssh.com";
        assert!(should_fallback_to_ssh_probe(stderr));
        assert!(!should_fallback_to_ssh_probe(
            "Unable to negotiate with host: no matching key exchange method found"
        ));
    }

    #[test]
    fn classifies_known_keys_by_alias_and_resolved_host() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "gpu-alias".to_owned(),
            user: None,
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: Some("10.0.0.7".to_owned()),
            resolved_port: Some(2200),
        };
        fs::write(&app, "[10.0.0.7]:2200 ssh-ed25519 AQID\n").expect("known host");
        let scan = parse_scan_output("10.0.0.7 ssh-ed25519 AQID\n").expect("scan");
        let manager = KnownHostsManager::new(&app, Some(user.clone()));
        assert_eq!(manager.classify(&target, &scan).expect("trusted"), HostKeyState::Trusted);
        manager.forget(&target).expect("forget");
        assert_eq!(fs::read_to_string(&app).expect("application file"), "");
        let _ = fs::remove_file(app);
        let _ = fs::remove_file(user);
    }

    #[test]
    fn classifies_unknown_trusted_and_changed_without_touching_user_file() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "example".to_owned(),
            user: None,
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: None,
            resolved_port: None,
        };
        let scan = parse_scan_output("example ssh-ed25519 AQID\n")
            .expect("scan");
        let manager = KnownHostsManager::new(&app, Some(user.clone()));
        assert_eq!(manager.classify(&target, &scan).expect("unknown"), HostKeyState::Unknown);
        manager.accept(&target, &scan).expect("accept app key");
        assert_eq!(manager.classify(&target, &scan).expect("trusted"), HostKeyState::Trusted);
        let app_before = fs::read_to_string(&app).expect("app file");
        fs::write(&user, "example ssh-ed25519 BAUG\n").expect("user file");
        assert_eq!(manager.classify(&target, &scan).expect("app remains trusted"), HostKeyState::Trusted);
        assert_eq!(fs::read_to_string(&user).expect("user unchanged"), "example ssh-ed25519 BAUG\n");
        manager.forget(&target).expect("forget app key");
        assert_eq!(manager.classify(&target, &scan).expect("changed user key"), HostKeyState::Changed);
        assert_eq!(fs::read_to_string(&app).expect("app file"), "");
        assert_eq!(app_before.lines().count(), 1);
        let _ = fs::remove_file(app);
        let _ = fs::remove_file(user);
    }

    #[test]
    fn changed_keys_cannot_be_accepted() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "example".to_owned(),
            user: None,
            port: None,
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: None,
            resolved_port: None,
        };
        let old = parse_scan_output("example ssh-ed25519 AQID\n").expect("old");
        let new = parse_scan_output("example ssh-ed25519 BAUG\n").expect("new");
        let manager = KnownHostsManager::new(&app, Some(user));
        manager.accept(&target, &old).expect("old accepted");
        fs::write(manager.paths.user.as_ref().expect("user path"), "example ssh-ed25519 BAUG\n")
            .expect("new user key");
        assert_eq!(manager.classify(&target, &new).expect("changed"), HostKeyState::Changed);
        assert!(manager.accept(&target, &new).is_err());
        let _ = fs::remove_file(app);
    }

    #[test]
    fn reads_hashed_user_known_hosts_without_writing_to_it() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "example".to_owned(),
            user: None,
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: None,
            resolved_port: None,
        };
        let scan = parse_scan_output("example ssh-ed25519 AQID\n").expect("scan");
        let salt = b"test-salt";
        let mut mac = Hmac::<Sha1>::new_from_slice(salt).expect("hmac");
        mac.update(b"example");
        let line = format!(
            "|1|{}|{} ssh-ed25519 AQID\n",
            STANDARD.encode(salt),
            STANDARD.encode(mac.finalize().into_bytes())
        );
        fs::write(&user, &line).expect("hashed user file");
        let manager = KnownHostsManager::new(&app, Some(user.clone()));
        assert_eq!(manager.classify(&target, &scan).expect("trusted"), HostKeyState::Trusted);
        assert_eq!(fs::read_to_string(&user).expect("user file"), line);
        let _ = fs::remove_file(app);
        let _ = fs::remove_file(user);
    }

    #[test]
    fn builds_safe_ssh_probe_arguments_without_spurious_positional_args() {
        let (app, user) = temp_paths();
        let target = SshTarget {
            alias: "3090".to_owned(),
            user: Some("test-user".to_owned()),
            port: Some(22),
            credential_identity: None,
            session_credential_token: None,
            session_credential_endpoint: None,
            known_hosts_file: None,
            user_known_hosts_file: None,
            resolved_host: None,
            resolved_port: None,
        };
        let manager = KnownHostsManager::new(&app, Some(user.clone()));
        let temp_hosts = PathBuf::from("temp_known_hosts");
        let args = manager.ssh_probe_arguments_with_config(&target, &temp_hosts, None);
        // Ensure "-T" is not followed by a spurious number or positional host argument
        let t_idx = args.iter().position(|a| a == "-T").expect("-T present");
        assert_ne!(args.get(t_idx + 1).map(|s| s.as_str()), Some("5"));
        assert_eq!(args.get(t_idx + 1).map(|s| s.as_str()), Some("-o"));
        // Ensure destination is after "--"
        let dash_idx = args.iter().position(|a| a == "--").expect("-- present");
        assert_eq!(args.get(dash_idx + 1).map(|s| s.as_str()), Some("test-user@3090"));
        assert_eq!(args.get(dash_idx + 2).map(|s| s.as_str()), Some("exit"));
        let _ = fs::remove_file(app);
        let _ = fs::remove_file(user);
    }
}
