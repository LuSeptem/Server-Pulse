use std::collections::HashMap;
use std::env;
use std::io::{Read, Write};
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;
use tokio::time::timeout;
use uuid::Uuid;
use zeroize::Zeroizing;

#[derive(Debug, Clone)]
pub struct SessionCredentialHandle {
    pub token: String,
    pub endpoint: String,
}

#[derive(Debug, Default)]
struct CredentialState {
    by_server: HashMap<String, String>,
    by_token: HashMap<String, Zeroizing<String>>,
}

#[derive(Debug, Clone, Default)]
pub struct SessionCredentialBroker {
    state: Arc<Mutex<CredentialState>>,
}

impl SessionCredentialBroker {
    pub async fn set(&self, server_id: &str, password: &str) -> SessionCredentialHandle {
        let token = Uuid::new_v4().to_string();
        let handle = SessionCredentialHandle {
            token: token.clone(),
            endpoint: endpoint_name(&token),
        };
        let mut state = self.state.lock().await;
        if let Some(previous) = state.by_server.insert(server_id.to_owned(), token.clone()) {
            state.by_token.remove(&previous);
        }
        state
            .by_token
            .insert(token, Zeroizing::new(password.to_owned()));
        handle
    }

    pub async fn prepare_listener(
        &self,
        server_id: &str,
        password: &str,
    ) -> Result<SessionCredentialHandle, String> {
        let handle = self.set(server_id, password).await;
        let state = self.state.clone();
        let token = handle.token.clone();
        let endpoint = handle.endpoint.clone();
        #[cfg(unix)]
        {
            let path = PathBuf::from(&endpoint);
            let _ = fs::remove_file(&path);
            let listener = tokio::net::UnixListener::bind(&path)
                .map_err(|error| format!("create askpass socket: {error}"))?;
            set_private_permissions(&path)?;
            tokio::spawn(async move {
                serve_unix(listener, state, token, path).await;
            });
        }
        #[cfg(windows)]
        {
            use tokio::net::windows::named_pipe::ServerOptions;
            let listener = ServerOptions::new()
                .first_pipe_instance(true)
                .create(&endpoint)
                .map_err(|error| format!("create askpass pipe: {error}"))?;
            tokio::spawn(async move {
                serve_windows(listener, state, token, endpoint).await;
            });
        }
        Ok(handle)
    }

    pub async fn clear(&self, server_id: &str) {
        let mut state = self.state.lock().await;
        if let Some(token) = state.by_server.remove(server_id) {
            state.by_token.remove(&token);
        }
    }

    pub async fn clear_all(&self) {
        let mut state = self.state.lock().await;
        state.by_server.clear();
        state.by_token.clear();
    }

    pub async fn password(&self, server_id: &str) -> Option<Zeroizing<String>> {
        let state = self.state.lock().await;
        let token = state.by_server.get(server_id)?;
        state.by_token.get(token).cloned()
    }

    #[cfg(test)]
    async fn take_token(&self, token: &str) -> Option<Zeroizing<String>> {
        self.state.lock().await.by_token.remove(token)
    }
}

#[cfg(windows)]
fn endpoint_name(token: &str) -> String {
    format!(r"\\.\pipe\serverpulse-askpass-{token}")
}

#[cfg(unix)]
fn endpoint_name(token: &str) -> String {
    std::env::temp_dir()
        .join(format!("serverpulse-askpass-{token}.sock"))
        .to_string_lossy()
        .into_owned()
}

#[cfg(not(any(unix, windows)))]
fn endpoint_name(token: &str) -> String {
    format!("serverpulse-askpass-{token}")
}

#[cfg(unix)]
use std::fs;
#[cfg(unix)]
use std::path::PathBuf;
#[cfg(unix)]
fn set_private_permissions(path: &PathBuf) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect askpass socket: {error}"))
}

#[cfg(unix)]
async fn serve_unix(
    listener: tokio::net::UnixListener,
    broker: Arc<Mutex<CredentialState>>,
    token: String,
    path: PathBuf,
) {
    let result = timeout(Duration::from_secs(15), async {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                break;
            };
            let mut supplied = Vec::new();
            if stream.read_to_end(&mut supplied).await.is_err() {
                continue;
            }
            let supplied = supplied.strip_suffix(&[b'\n']).unwrap_or(&supplied);
            if supplied == token.as_bytes() {
                let password = broker.lock().await.by_token.remove(&token);
                if let Some(password) = password {
                    let _ = stream.write_all(password.as_bytes()).await;
                    let _ = stream.write_all(b"\n").await;
                    let _ = stream.shutdown().await;
                }
                break;
            }
        }
    })
    .await;
    let _ = result;
    let _ = fs::remove_file(path);
}

#[cfg(windows)]
async fn serve_windows(
    mut server: tokio::net::windows::named_pipe::NamedPipeServer,
    broker: Arc<Mutex<CredentialState>>,
    token: String,
    endpoint: String,
) {
    use tokio::net::windows::named_pipe::ServerOptions;
    let _ = timeout(Duration::from_secs(15), async {
        loop {
            if server.connect().await.is_err() {
                break;
            }
            let mut supplied = Vec::new();
            if read_pipe_token(&mut server, &mut supplied).await.is_err() {
                let _ = server.disconnect();
                break;
            }
            if supplied == token.as_bytes() {
                let password = broker.lock().await.by_token.remove(&token);
                if let Some(password) = password {
                    let _ = server.write_all(password.as_bytes()).await;
                    let _ = server.write_all(b"\n").await;
                    let _ = server.shutdown().await;
                }
                break;
            }
            let _ = server.disconnect();
            server = match ServerOptions::new().create(&endpoint) {
                Ok(next) => next,
                Err(_) => break,
            };
        }
    })
    .await;
}

pub fn askpass_password() -> Result<Option<String>, String> {
    let Some(token) = env::var_os("SERVERPULSE_SESSION_TOKEN") else {
        return Ok(None);
    };
    let Some(endpoint) = env::var_os("SERVERPULSE_SESSION_ENDPOINT") else {
        return Ok(None);
    };
    let token = token.to_string_lossy().into_owned();
    let endpoint = endpoint.to_string_lossy().into_owned();
    let mut last_error = None;
    for _ in 0..40 {
        match read_endpoint(&endpoint, &token) {
            Ok(password) => return Ok(Some(password)),
            Err(error) => last_error = Some(error),
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    Err(last_error.unwrap_or_else(|| "askpass endpoint unavailable".to_owned()))
}

fn read_endpoint(endpoint: &str, token: &str) -> Result<String, String> {
    #[cfg(unix)]
    {
        use std::os::unix::net::UnixStream;
        let mut stream = UnixStream::connect(endpoint).map_err(|error| error.to_string())?;
        stream
            .write_all(format!("{token}\n").as_bytes())
            .map_err(|error| error.to_string())?;
        stream
            .shutdown(std::net::Shutdown::Write)
            .map_err(|error| error.to_string())?;
        let mut bytes = Vec::new();
        stream
            .read_to_end(&mut bytes)
            .map_err(|error| error.to_string())?;
        let password =
            String::from_utf8(bytes).map_err(|_| "askpass response is not UTF-8".to_owned())?;
        return Ok(password.trim_end_matches(['\r', '\n']).to_owned());
    }
    #[cfg(windows)]
    {
        let mut stream = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(endpoint)
            .map_err(|error| error.to_string())?;
        stream
            .write_all(format!("{token}\n").as_bytes())
            .map_err(|error| error.to_string())?;
        let mut bytes = Vec::new();
        stream
            .read_to_end(&mut bytes)
            .map_err(|error| error.to_string())?;
        let password =
            String::from_utf8(bytes).map_err(|_| "askpass response is not UTF-8".to_owned())?;
        return Ok(password.trim_end_matches(['\r', '\n']).to_owned());
    }
    #[allow(unreachable_code)]
    Err("local askpass transport is unsupported on this platform".to_owned())
}

#[cfg(windows)]
async fn read_pipe_token(
    pipe: &mut tokio::net::windows::named_pipe::NamedPipeServer,
    supplied: &mut Vec<u8>,
) -> std::io::Result<()> {
    let mut byte = [0u8; 1];
    loop {
        let count = pipe.read(&mut byte).await?;
        if count == 0 || byte[0] == b'\n' {
            break;
        }
        if supplied.len() >= 256 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "askpass token is too long",
            ));
        }
        supplied.push(byte[0]);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn session_secret_is_not_persisted_and_token_is_one_time() {
        let broker = SessionCredentialBroker::default();
        let handle = broker.set("server-1", "secret").await;
        assert!(!handle.token.contains("secret"));
        assert!(broker
            .take_token(&format!("wrong-{}", handle.token))
            .await
            .is_none());
        let first = broker.take_token(&handle.token).await.expect("token");
        assert_eq!(&*first, "secret");
        assert!(broker.take_token(&handle.token).await.is_none());
        broker.clear_all().await;
    }

    #[tokio::test]
    async fn replacing_server_secret_zeroizes_old_token() {
        let broker = SessionCredentialBroker::default();
        let first = broker.set("server-1", "old").await;
        let second = broker.set("server-1", "new").await;
        assert!(broker.take_token(&first.token).await.is_none());
        assert_eq!(
            &*broker.take_token(&second.token).await.expect("new"),
            "new"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn local_endpoint_rejects_wrong_token_and_allows_one_correct_read() {
        let broker = SessionCredentialBroker::default();
        let handle = broker
            .prepare_listener("server-1", "channel-secret")
            .await
            .expect("listener");
        let wrong_endpoint = handle.endpoint.clone();
        let wrong =
            tokio::task::spawn_blocking(move || read_endpoint(&wrong_endpoint, "wrong-token"))
                .await
                .expect("wrong client task");
        assert!(wrong.is_err() || wrong.expect("wrong response").is_empty());

        let correct_endpoint = handle.endpoint.clone();
        let correct_token = handle.token.clone();
        let correct =
            tokio::task::spawn_blocking(move || read_endpoint(&correct_endpoint, &correct_token))
                .await
                .expect("correct client task")
                .expect("correct response");
        assert_eq!(correct, "channel-secret");

        let second_endpoint = handle.endpoint.clone();
        let second_token = handle.token.clone();
        let second =
            tokio::task::spawn_blocking(move || read_endpoint(&second_endpoint, &second_token))
                .await
                .expect("second client task");
        assert!(second.is_err() || second.expect("second response").is_empty());
        broker.clear_all().await;
    }
}
