use serverpulse_core::{parse_metric_output, MetricSnapshot, ServerPulseError};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdout};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use std::sync::Arc;

use crate::{SshTarget, SystemOpenSsh};

const FRAME_BEGIN: &str = "SERVERPULSE_FRAME_BEGIN";
const FRAME_END: &str = "SERVERPULSE_FRAME_END";
const MAX_FRAME_BYTES: usize = 1024 * 1024;

pub struct SshStream {
    child: Child,
    stdout: BufReader<ChildStdout>,
    stderr_task: Option<JoinHandle<()>>,
    stderr: Arc<Mutex<Vec<u8>>>,
    frame_timeout: Duration,
}

impl SshStream {
    pub async fn next_snapshot(&mut self) -> Result<MetricSnapshot, ServerPulseError> {
        let mut line = String::new();
        loop {
            line.clear();
            let read = timeout(self.frame_timeout, self.stdout.read_line(&mut line))
                .await
                .map_err(|_| ServerPulseError::Timeout("SSH stream frame timed out".to_owned()))?
                .map_err(ServerPulseError::Io)?;
            if read == 0 {
                return Err(self.stream_exit_error("SSH stream exited before a frame").await);
            }
            if line.trim_end_matches(['\r', '\n']) == FRAME_BEGIN {
                break;
            }
        }

        let mut frame = String::new();
        loop {
            line.clear();
            let read = timeout(self.frame_timeout, self.stdout.read_line(&mut line))
                .await
                .map_err(|_| ServerPulseError::Timeout("SSH stream frame timed out".to_owned()))?
                .map_err(ServerPulseError::Io)?;
            if read == 0 {
                return Err(self.stream_exit_error("SSH stream exited inside a frame").await);
            }
            let clean = line.trim_end_matches(['\r', '\n']);
            if clean == FRAME_END {
                return parse_metric_output(&frame);
            }
            frame.push_str(&line);
            if frame.len() > MAX_FRAME_BYTES {
                return Err(ServerPulseError::InvalidMetricOutput(
                    "SSH stream frame exceeded the size limit".to_owned(),
                ));
            }
        }
    }

    async fn stream_exit_error(&mut self, fallback: &str) -> ServerPulseError {
        let _ = self.child.try_wait();
        if let Some(task) = self.stderr_task.take() {
            let _ = timeout(Duration::from_millis(100), task).await;
        }
        let detail = String::from_utf8_lossy(&self.stderr.lock().await).trim().to_owned();
        if is_authentication_error(&detail) {
            return ServerPulseError::Authentication(if detail.is_empty() {
                fallback.to_owned()
            } else {
                detail
            });
        }
        ServerPulseError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            if detail.is_empty() {
                fallback.to_owned()
            } else {
                format!("{fallback}: {detail}")
            },
        ))
    }

    pub async fn shutdown(mut self) -> Result<(), ServerPulseError> {
        let result = if self.child.try_wait().map_err(ServerPulseError::Io)?.is_none() {
            self.child.kill().await.map_err(ServerPulseError::Io)?;
            self.child.wait().await.map_err(ServerPulseError::Io)?;
            Ok(())
        } else {
            Ok(())
        };
        if let Some(task) = self.stderr_task.take() {
            task.abort();
        }
        result
    }
}

impl Drop for SshStream {
    fn drop(&mut self) {
        if let Some(task) = self.stderr_task.take() {
            task.abort();
        }
    }
}

pub fn framed_sampler_script(sampler: &str, interval: Duration) -> String {
    let clean = sampler.replace("\r\n", "\n").replace('\r', "");
    let body = clean.strip_prefix("#!/bin/sh\n").unwrap_or(&clean);
    format!(
        "while :; do\n  printf '%s\\n' '{FRAME_BEGIN}'\n  (\n{body}\n  )\n  printf '%s\\n' '{FRAME_END}'\n  sleep {seconds}\ndone\n",
        FRAME_BEGIN = FRAME_BEGIN,
        FRAME_END = FRAME_END,
        body = body,
        seconds = interval.as_secs_f64().max(0.1),
    )
}

pub fn parse_framed_text(text: &str) -> Result<Vec<MetricSnapshot>, ServerPulseError> {
    let mut snapshots = Vec::new();
    let mut active = false;
    let mut frame = String::new();
    for raw in text.lines() {
        match raw {
            FRAME_BEGIN if !active => {
                active = true;
                frame.clear();
            }
            FRAME_END if active => {
                snapshots.push(parse_metric_output(&frame)?);
                active = false;
            }
            _ if active => {
                frame.push_str(raw);
                frame.push('\n');
            }
            _ => {}
        }
    }
    if active {
        return Err(ServerPulseError::InvalidMetricOutput(
            "SSH stream ended inside a frame".to_owned(),
        ));
    }
    Ok(snapshots)
}

impl SystemOpenSsh {
    pub async fn open_stream(
        &self,
        target: &SshTarget,
        sampler: &str,
        interval: Duration,
    ) -> Result<SshStream, ServerPulseError> {
        let mut child = self.spawn_command(target).await?;
        let Some(mut stdin) = child.stdin.take() else {
            return Err(ServerPulseError::Io(std::io::Error::other(
                "SSH stream stdin was not piped",
            )));
        };
        let script = framed_sampler_script(sampler, interval);
        if let Err(error) = stdin.write_all(script.as_bytes()).await {
            let _ = child.kill().await;
            return Err(ServerPulseError::Io(error));
        }
        stdin.flush().await.map_err(ServerPulseError::Io)?;
        drop(stdin);
        let stdout = child.stdout.take().ok_or_else(|| {
            ServerPulseError::Io(std::io::Error::other("SSH stream stdout was not piped"))
        })?;
        let stderr_buffer = Arc::new(Mutex::new(Vec::new()));
        let stderr_task = child.stderr.take().map(|mut stderr| {
            let stderr_buffer = stderr_buffer.clone();
            tokio::spawn(async move {
                let mut chunk = [0u8; 4096];
                loop {
                    let read = match stderr.read(&mut chunk).await {
                        Ok(0) | Err(_) => break,
                        Ok(read) => read,
                    };
                    let mut buffer = stderr_buffer.lock().await;
                    let remaining = (16 * 1024usize).saturating_sub(buffer.len());
                    if remaining > 0 {
                        buffer.extend_from_slice(&chunk[..read.min(remaining)]);
                    }
                }
            })
        });
        Ok(SshStream {
            child,
            stdout: BufReader::new(stdout),
            stderr_task,
            stderr: stderr_buffer,
            frame_timeout: self.timeout + interval + Duration::from_secs(2),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "PROTOCOL_VERSION=2\nHOSTNAME=test\nCPU_PERCENT=1\nMEM_TOTAL_KIB=100\nMEM_USED_KIB=20\nMEM_PERCENT=20\nLOAD_1=0\nLOAD_5=0\nLOAD_15=0\nUPTIME_SECONDS=1\nCPU_USER_STATUS=unavailable\nMEMORY_USER_STATUS=unavailable\nGPUS_BEGIN\nGPUS_END\nGPU_USER_STATUS=unavailable\n";

    #[test]
    fn wrapper_contains_repeating_framed_sampler() {
        let script = framed_sampler_script("#!/bin/sh\necho PROTOCOL_VERSION=2", Duration::from_secs(5));
        assert!(script.contains("SERVERPULSE_FRAME_BEGIN"));
        assert!(script.contains("SERVERPULSE_FRAME_END"));
        assert!(script.contains("sleep 5"));
        assert!(script.contains("echo PROTOCOL_VERSION=2"));
        assert!(!script.contains("#!/bin/sh\n#!/bin/sh"));
    }

    #[test]
    fn parses_multiple_frames_and_ignores_outside_text() {
        let text = format!(
            "warning\n{begin}\n{sample}{end}\nnoise\n{begin}\n{sample}{end}\n",
            begin = FRAME_BEGIN,
            end = FRAME_END,
            sample = SAMPLE
        );
        let frames = parse_framed_text(&text).expect("frames");
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].hostname, "test");
    }

    #[test]
    fn rejects_incomplete_and_corrupt_frames() {
        assert!(parse_framed_text(&format!("{FRAME_BEGIN}\n{SAMPLE}")).is_err());
        assert!(parse_framed_text(&format!("{FRAME_BEGIN}\nnot-valid\n{FRAME_END}")).is_err());
    }

    #[test]
    fn classifies_authentication_errors_without_classifying_network_resets() {
        assert!(is_authentication_error("Permission denied (publickey,password)."));
        assert!(is_authentication_error("Host key verification failed."));
        assert!(!is_authentication_error("Connection reset by peer"));
    }
}

fn is_authentication_error(detail: &str) -> bool {
    let lower = detail.to_ascii_lowercase();
    [
        "permission denied",
        "authentication failed",
        "no supported authentication methods",
        "too many authentication failures",
        "host key verification failed",
        "host key has changed",
        "remote host identification has changed",
        "offending ",
        "sign_and_send_pubkey",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}
