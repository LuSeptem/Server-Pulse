use async_trait::async_trait;
use serverpulse_core::{parse_metric_output, MetricSnapshot, ServerPulseError};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
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
            command.creation_flags(0x0000_0200);
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
}
