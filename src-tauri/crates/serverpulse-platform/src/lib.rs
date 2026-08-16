use serverpulse_core::{merge_jsonl_lines, parse_server_configs, read_history_jsonl, HistoryEntry, ServerConfig, ServerPulseError};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone)]
pub struct DataRootManager {
    pub default_root: PathBuf,
    pub pointer_path: PathBuf,
}

impl Default for DataRootManager {
    fn default() -> Self {
        let base = if cfg!(windows) {
            std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("USERPROFILE").map(|value| PathBuf::from(value).join("AppData/Local")))
                .unwrap_or_else(|| PathBuf::from("."))
        } else if cfg!(target_os = "macos") {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."))
                .join("Library/Application Support")
        } else {
            std::env::var_os("XDG_DATA_HOME")
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|value| PathBuf::from(value).join(".local/share")))
                .unwrap_or_else(|| PathBuf::from("."))
        };
        let default_root = base.join("ServerPulse");
        let pointer_path = base.join("ServerPulse.location.json");
        Self {
            default_root,
            pointer_path,
        }
    }
}

impl DataRootManager {
    pub fn validate_local_path(&self, path: &Path, create: bool) -> Result<PathBuf, ServerPulseError> {
        if !path.is_absolute() {
            return Err(ServerPulseError::InvalidConfig("data root must be absolute".to_owned()));
        }
        if cfg!(windows) && (path.to_string_lossy().starts_with("\\\\") || path.to_string_lossy().starts_with("//")) {
            return Err(ServerPulseError::InvalidConfig("UNC/network data roots are not supported".to_owned()));
        }
        if create {
            fs::create_dir_all(path)?;
        }
        if !path.is_dir() {
            return Err(ServerPulseError::InvalidConfig("data root must be a directory".to_owned()));
        }
        let probe = path.join(format!(".serverpulse-write-{}.tmp", unique_suffix()));
        let mut file = File::create(&probe)?;
        file.write_all(b"Server Pulse write test")?;
        drop(file);
        fs::remove_file(probe)?;
        Ok(path.to_path_buf())
    }

    pub fn resolve(&self) -> Result<PathBuf, ServerPulseError> {
        self.validate_local_path(&self.default_root, true)?;
        if let Ok(pointer) = fs::read_to_string(&self.pointer_path) {
            if let Ok(value) = serde_json::from_str::<LocationPointer>(&pointer) {
                if !value.preferred_data_root_path.is_empty() {
                    let path = PathBuf::from(value.preferred_data_root_path);
                    if self.validate_local_path(&path, false).is_ok() {
                        return Ok(path);
                    }
                }
            }
        }
        Ok(self.default_root.clone())
    }

    pub fn write_pointer(&self, preferred: &Path, active: &Path, pending_sync: bool) -> Result<(), ServerPulseError> {
        if let Some(parent) = self.pointer_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let pointer = LocationPointer {
            version: 1,
            preferred_data_root_path: preferred.to_string_lossy().into_owned(),
            active_data_root_path: active.to_string_lossy().into_owned(),
            pending_sync,
            updated_at: chrono::Utc::now().to_rfc3339(),
        };
        atomic_write(&self.pointer_path, serde_json::to_string_pretty(&pointer)?.as_bytes())
    }

    pub fn preview_import(&self, source: &Path, target: &Path) -> Result<MigrationPreview, ServerPulseError> {
        let source = self.validate_local_path(source, false)?;
        let target = self.validate_local_path(target, true)?;
        let mut files = Vec::new();
        let mut bytes = 0u64;
        collect_files(&source, &source, &mut files, &mut bytes)?;
        Ok(MigrationPreview {
            source: source.to_string_lossy().into_owned(),
            target: target.to_string_lossy().into_owned(),
            file_count: files.len() as u32,
            bytes,
            has_servers: files.iter().any(|item| item == "servers.json"),
            history_files: files.iter().filter(|item| item.starts_with("history/") || item.starts_with("history\\")).count() as u32,
        })
    }

    pub fn import(&self, source: &Path, target: &Path, mode: ConflictMode) -> Result<MigrationResult, ServerPulseError> {
        let preview = self.preview_import(source, target)?;
        if mode == ConflictMode::Cancel {
            return Ok(MigrationResult { status: "cancelled".to_owned(), backup: None, imported_files: 0, preview });
        }
        let source = PathBuf::from(&preview.source);
        let target = PathBuf::from(&preview.target);
        let backup = target.with_extension(format!("backup-{}", unique_suffix()));
        if target.exists() {
            fs::create_dir_all(&backup)?;
        }
        let mut imported = 0u32;
        copy_tree(&source, &target, &backup, mode, &mut imported)?;
        Ok(MigrationResult {
            status: "imported".to_owned(),
            backup: backup.exists().then(|| backup.to_string_lossy().into_owned()),
            imported_files: imported,
            preview,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocationPointer {
    pub version: u32,
    pub preferred_data_root_path: String,
    pub active_data_root_path: String,
    pub pending_sync: bool,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ConflictMode {
    Cancel,
    Merge,
    Overwrite,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationPreview {
    pub source: String,
    pub target: String,
    pub file_count: u32,
    pub bytes: u64,
    pub has_servers: bool,
    pub history_files: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MigrationResult {
    pub status: String,
    pub backup: Option<String>,
    pub imported_files: u32,
    pub preview: MigrationPreview,
}

fn unique_suffix() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
        .to_string()
}

fn collect_files(root: &Path, current: &Path, files: &mut Vec<String>, bytes: &mut u64) -> Result<(), ServerPulseError> {
    for entry in fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            collect_files(root, &path, files, bytes)?;
        } else {
            let metadata = entry.metadata()?;
            *bytes += metadata.len();
            files.push(path.strip_prefix(root).unwrap_or(&path).to_string_lossy().replace('\\', "/"));
        }
    }
    Ok(())
}

fn copy_tree(source: &Path, target: &Path, backup: &Path, mode: ConflictMode, imported: &mut u32) -> Result<(), ServerPulseError> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let source_path = entry.path();
        let relative = source_path.strip_prefix(source).unwrap_or(&source_path);
        let target_path = target.join(relative);
        if source_path.is_dir() {
            fs::create_dir_all(&target_path)?;
            copy_tree(&source_path, &target_path, backup, mode.clone(), imported)?;
            continue;
        }
        if target_path.exists() {
            if mode == ConflictMode::Merge && relative.to_string_lossy().replace('\\', "/").starts_with("history/") {
                let existing = fs::read_to_string(&target_path).unwrap_or_default();
                let incoming = fs::read_to_string(&source_path).unwrap_or_default();
                atomic_write(&target_path, merge_jsonl_lines(&existing, &incoming).as_bytes())?;
                *imported += 1;
                continue;
            }
            if mode == ConflictMode::Merge && relative == Path::new("servers.json") {
                let existing = fs::read_to_string(&target_path).unwrap_or_default();
                let incoming = fs::read_to_string(&source_path).unwrap_or_default();
                let merged = merge_server_files(&existing, &incoming)?;
                atomic_write(&target_path, merged.as_bytes())?;
                *imported += 1;
                continue;
            }
            fs::create_dir_all(backup)?;
            let backup_path = backup.join(relative);
            if let Some(parent) = backup_path.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::copy(&target_path, backup_path)?;
            if mode == ConflictMode::Merge {
                continue;
            }
        }
        if let Some(parent) = target_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::copy(&source_path, &target_path)?;
        *imported += 1;
    }
    Ok(())
}

fn merge_server_files(existing: &str, incoming: &str) -> Result<String, ServerPulseError> {
    let mut target: serde_json::Value = serde_json::from_str(existing).unwrap_or_else(|_| serde_json::json!({ "servers": [] }));
    let source: serde_json::Value = serde_json::from_str(incoming)?;
    let target_servers = target["servers"].as_array_mut().ok_or_else(|| ServerPulseError::InvalidHistory("servers.json has no servers array".to_owned()))?;
    let source_servers = source["servers"].as_array().cloned().unwrap_or_default();
    for candidate in source_servers {
        let id = candidate.get("id").and_then(|value| value.as_str()).unwrap_or_default();
        if let Some(existing) = target_servers.iter_mut().find(|item| item.get("id").and_then(|value| value.as_str()) == Some(id)) {
            if existing != &candidate {
                continue;
            }
        } else {
            target_servers.push(candidate);
        }
    }
    Ok(serde_json::to_string_pretty(&target)?)
}

pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), ServerPulseError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("tmp-{}", unique_suffix()));
    {
        let mut file = File::create(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    if path.exists() {
        fs::remove_file(path)?;
    }
    fs::rename(temp, path)?;
    Ok(())
}

pub struct FileLock {
    path: PathBuf,
}

impl FileLock {
    pub fn acquire(path: impl AsRef<Path>, timeout: Duration) -> Result<Self, ServerPulseError> {
        let path = path.as_ref().to_path_buf();
        let deadline = std::time::Instant::now() + timeout;
        loop {
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut file) => {
                    file.write_all(std::process::id().to_string().as_bytes())?;
                    return Ok(Self { path });
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists && std::time::Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(25));
                }
                Err(error) => return Err(ServerPulseError::Io(error)),
            }
        }
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub fn read_server_configs(data_root: &Path) -> Result<Option<Vec<ServerConfig>>, ServerPulseError> {
    let path = data_root.join("servers.json");
    if !path.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(path)?;
    Ok(Some(parse_server_configs(&text)?))
}

pub fn write_server_configs(data_root: &Path, servers: &[ServerConfig]) -> Result<(), ServerPulseError> {
    fs::create_dir_all(data_root)?;
    for server in servers {
        server.validate()?;
    }
    let path = data_root.join("servers.json");
    let lock = FileLock::acquire(data_root.join(".servers.lock"), Duration::from_secs(10))?;
    let mut document = if path.exists() {
        serde_json::from_str::<serde_json::Value>(&fs::read_to_string(&path)?)?
    } else {
        serde_json::json!({})
    };
    if !document.is_object() {
        document = serde_json::json!({});
    }
    if let Some(object) = document.as_object_mut() {
        object.remove("Servers");
    }
    document["servers"] = serde_json::to_value(servers)?;
    let bytes = serde_json::to_vec_pretty(&document)?;
    atomic_write(&path, &bytes)?;
    drop(lock);
    Ok(())
}

pub trait CredentialStore: Send + Sync {
    fn get(&self, identity: &str) -> Result<Option<String>, ServerPulseError>;
    fn set(&self, identity: &str, password: &str) -> Result<(), ServerPulseError>;
    fn delete(&self, identity: &str) -> Result<(), ServerPulseError>;
}

#[derive(Debug, Clone)]
pub struct KeyringCredentialStore {
    service: String,
}

impl Default for KeyringCredentialStore {
    fn default() -> Self {
        Self { service: "ServerPulse".to_owned() }
    }
}

impl CredentialStore for KeyringCredentialStore {
    fn get(&self, identity: &str) -> Result<Option<String>, ServerPulseError> {
        let entry = keyring::Entry::new(&self.service, identity)
            .map_err(|error| ServerPulseError::Authentication(error.to_string()))?;
        match entry.get_password() {
            Ok(value) => Ok(Some(value)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(error) => Err(ServerPulseError::Authentication(error.to_string())),
        }
    }

    fn set(&self, identity: &str, password: &str) -> Result<(), ServerPulseError> {
        let entry = keyring::Entry::new(&self.service, identity)
            .map_err(|error| ServerPulseError::Authentication(error.to_string()))?;
        entry.set_password(password)
            .map_err(|error| ServerPulseError::Authentication(error.to_string()))
    }

    fn delete(&self, identity: &str) -> Result<(), ServerPulseError> {
        let entry = keyring::Entry::new(&self.service, identity)
            .map_err(|error| ServerPulseError::Authentication(error.to_string()))?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(error) => Err(ServerPulseError::Authentication(error.to_string())),
        }
    }
}

#[derive(Debug, Clone)]
pub struct JsonHistoryStore {
    pub history_root: PathBuf,
}

impl JsonHistoryStore {
    pub fn new(data_root: impl AsRef<Path>) -> Self {
        Self { history_root: data_root.as_ref().join("history") }
    }

    pub fn append_jsonl(&self, day: &str, line: &str) -> Result<(), ServerPulseError> {
        fs::create_dir_all(&self.history_root)?;
        let path = self.history_root.join(format!("{day}.v2.jsonl"));
        let lock = FileLock::acquire(self.history_root.join(".history.lock"), Duration::from_secs(30))?;
        let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
        writeln!(file, "{}", line.trim())?;
        drop(lock);
        Ok(())
    }

    pub fn read_jsonl(&self, day: &str) -> Result<Vec<HistoryEntry>, ServerPulseError> {
        let path = self.history_root.join(format!("{day}.v2.jsonl"));
        if !path.exists() {
            return Ok(Vec::new());
        }
        let text = fs::read_to_string(path)?;
        Ok(read_history_jsonl(&text).entries)
    }

    pub fn merge_jsonl(&self, day: &str, incoming: &str) -> Result<usize, ServerPulseError> {
        fs::create_dir_all(&self.history_root)?;
        let path = self.history_root.join(format!("{day}.v2.jsonl"));
        let lock = FileLock::acquire(self.history_root.join(".history.lock"), Duration::from_secs(30))?;
        let existing = fs::read_to_string(&path).unwrap_or_default();
        let merged = merge_jsonl_lines(&existing, incoming);
        let count = read_history_jsonl(&merged).entries.len();
        atomic_write(&path, merged.as_bytes())?;
        drop(lock);
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_root_is_platform_specific() {
        let root = DataRootManager::default();
        assert!(root.default_root.ends_with("ServerPulse"));
        assert!(root.pointer_path.ends_with("ServerPulse.location.json"));
    }

    #[test]
    fn file_lock_is_released_on_drop() {
        let root = std::env::temp_dir().join(format!("serverpulse-lock-{}", unique_suffix()));
        let lock_path = root.join("lock");
        fs::create_dir_all(&root).expect("temp root");
        {
            let _lock = FileLock::acquire(&lock_path, Duration::from_secs(1)).expect("lock");
            assert!(lock_path.exists());
        }
        assert!(!lock_path.exists());
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn jsonl_store_round_trip() {
        let root = std::env::temp_dir().join(format!("serverpulse-history-{}", unique_suffix()));
        let store = JsonHistoryStore::new(&root);
        store.append_jsonl("2026-08-15", r#"{"Version":2,"Record":{}}"#).expect("append");
        assert_eq!(store.read_jsonl("2026-08-15").expect("read").len(), 1);
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn server_config_store_round_trip() {
        let root = std::env::temp_dir().join(format!("serverpulse-servers-{}", unique_suffix()));
        let servers = vec![ServerConfig {
            id: "demo".to_owned(),
            label: "Demo".to_owned(),
            host: "demo".to_owned(),
            user: Some("alice".to_owned()),
            port: Some(2222),
            monitored: true,
            passwordless: true,
        }];
        write_server_configs(&root, &servers).expect("write servers");
        assert_eq!(read_server_configs(&root).expect("read servers"), Some(servers));
        let _ = fs::remove_dir_all(root);
    }
}
