#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use chrono::{NaiveDate, SecondsFormat, Utc};
use serverpulse_core::{history_day, AppError, MetricSnapshot, RetryState, ServerConfig};
use serverpulse_platform::{
    read_server_configs, write_server_configs, ConflictMode, CredentialStore, DataRootManager,
    JsonHistoryStore, KeyringCredentialStore,
};
use serverpulse_ssh::{SshTarget, SshTransport, SystemOpenSsh};
use serde::Serialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

const SAMPLE_SCRIPT: &str = include_str!("../../assets/serverpulse-sample.sh");
const SEED_SERVERS: &str = include_str!("../../config/servers.json");

struct AppState {
    tasks: Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
    snapshots: Arc<Mutex<HashMap<String, MetricSnapshot>>>,
    statuses: Arc<Mutex<HashMap<String, String>>>,
    errors: Arc<Mutex<HashMap<String, String>>>,
    interval_seconds: Arc<Mutex<u64>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            snapshots: Arc::new(Mutex::new(HashMap::new())),
            statuses: Arc::new(Mutex::new(HashMap::new())),
            errors: Arc::new(Mutex::new(HashMap::new())),
            interval_seconds: Arc::new(Mutex::new(5)),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct MonitorStateResponse {
    snapshots: HashMap<String, MetricSnapshot>,
    statuses: HashMap<String, String>,
    errors: HashMap<String, String>,
    interval_seconds: u64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotEvent {
    server_id: String,
    timestamp: String,
    sequence: u64,
    payload: MetricSnapshot,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusPayload {
    status: String,
    detail: Option<AppError>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct StatusEvent {
    server_id: String,
    timestamp: String,
    sequence: u64,
    payload: StatusPayload,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryResponse {
    entries: Vec<serverpulse_core::HistoryEntry>,
    corrupt_lines: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct SshConfigInfo {
    path: Option<String>,
    aliases: Vec<String>,
    candidates: Vec<ServerConfig>,
    error: Option<String>,
}

fn to_command_error(error: impl std::fmt::Display) -> String {
    error.to_string()
}

fn parse_servers(text: &str) -> Result<Vec<ServerConfig>, String> {
    serverpulse_core::parse_server_configs(text).map_err(to_command_error)
}

fn discovered_servers() -> Vec<ServerConfig> {
    SystemOpenSsh::default()
        .discover_config_aliases()
        .unwrap_or_default()
        .into_iter()
        .map(|alias| ServerConfig {
            id: alias.clone(),
            label: alias.clone(),
            host: alias,
            user: None,
            port: None,
            monitored: false,
            passwordless: true,
        })
        .collect()
}

fn merge_discovered_servers(servers: &mut Vec<ServerConfig>, discovered: Vec<ServerConfig>) {
    for candidate in discovered {
        if servers.iter().any(|server| {
            server.id.eq_ignore_ascii_case(&candidate.id)
                || server.host.eq_ignore_ascii_case(&candidate.host)
        }) {
            continue;
        }
        servers.push(candidate);
    }
}

fn load_servers() -> Result<Vec<ServerConfig>, String> {
    let manager = DataRootManager::default();
    if let Ok(root) = manager.resolve() {
        if let Some(mut servers) = read_server_configs(&root).map_err(to_command_error)? {
            merge_discovered_servers(&mut servers, discovered_servers());
            return Ok(servers);
        }
    }

    let discovered = discovered_servers();
    if !discovered.is_empty() {
        return Ok(discovered);
    }

    let repository_seed = std::env::current_dir().map_err(to_command_error)?.join("config/servers.json");
    if repository_seed.exists() {
        return parse_servers(&fs::read_to_string(repository_seed).map_err(to_command_error)?);
    }
    parse_servers(SEED_SERVERS)
}

fn writable_servers() -> Result<(std::path::PathBuf, Vec<ServerConfig>), String> {
    let root = DataRootManager::default().resolve().map_err(to_command_error)?;
    let servers = read_server_configs(&root)
        .map_err(to_command_error)?
        .unwrap_or_else(discovered_servers);
    Ok((root, servers))
}

fn history_line(server: &ServerConfig, timestamp: &str, snapshot: &MetricSnapshot) -> Result<String, String> {
    serde_json::to_string(&serde_json::json!({
        "Version": 2,
        "Record": {
            "Timestamp": timestamp,
            "SampleCount": 1,
            "Servers": [{
                "Id": server.id,
                "Label": server.label,
                "Host": server.host,
                "OnlineSamples": 1,
                "TotalSamples": 1,
                "LatencyMs": serde_json::Value::Null,
                "Hostname": snapshot.hostname,
                "CpuPercent": snapshot.cpu_percent,
                "MemoryUsedMiB": snapshot.memory_used_mib,
                "MemoryTotalMiB": snapshot.memory_total_mib,
                "MemoryPercent": snapshot.memory_percent,
                "LoadOne": snapshot.load_one,
                "LoadFive": snapshot.load_five,
                "LoadFifteen": snapshot.load_fifteen,
                "UptimeSeconds": snapshot.uptime_seconds,
                "Gpus": &snapshot.gpus,
            }]
        }
    }))
    .map_err(to_command_error)
}

fn credential_identity(server: &ServerConfig) -> String {
    format!(
        "{}@{}:{}",
        server.user.as_deref().unwrap_or("default"),
        server.host,
        server.port.unwrap_or(22)
    )
}

fn target_with_saved_credential(server: &ServerConfig) -> SshTarget {
    let mut target = SshTarget::from_server(server);
    let identity = credential_identity(server);
    if !server.passwordless
        && KeyringCredentialStore::default()
            .get(&identity)
            .ok()
            .flatten()
            .is_some()
    {
        target.credential_identity = Some(identity);
    }
    target
}

fn spawn_monitoring_task(
    app: AppHandle,
    state_snapshots: Arc<Mutex<HashMap<String, MetricSnapshot>>>,
    state_statuses: Arc<Mutex<HashMap<String, String>>>,
    state_errors: Arc<Mutex<HashMap<String, String>>>,
    server: ServerConfig,
    interval: Duration,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let ssh = SystemOpenSsh::default();
        let id = server.id.clone();
        let target = target_with_saved_credential(&server);
        let data_root = DataRootManager::default().resolve().ok();
        let history_store = data_root.as_ref().map(|root| JsonHistoryStore::new(root));
        let mut sequence = 0u64;
        let mut retry = RetryState::default();
        state_statuses.lock().await.insert(id.clone(), "connecting".to_owned());
        let _ = app.emit(
            "server.status",
            StatusEvent {
                server_id: id.clone(),
                timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
                sequence: {
                    sequence = sequence.saturating_add(1);
                    sequence
                },
                payload: StatusPayload {
                    status: "connecting".to_owned(),
                    detail: None,
                },
            },
        );
        loop {
            match ssh.collect_once(&target, SAMPLE_SCRIPT).await {
                Ok(snapshot) => {
                    retry.reset();
                    sequence = sequence.saturating_add(1);
                    let now = Utc::now();
                    let timestamp = now.to_rfc3339_opts(SecondsFormat::Secs, true);
                    if let (Some(store), Ok(line)) = (&history_store, history_line(&server, &timestamp, &snapshot)) {
                        let _ = store.append_jsonl(&history_day(now), &line);
                    }
                    state_snapshots.lock().await.insert(id.clone(), snapshot.clone());
                    state_statuses.lock().await.insert(id.clone(), "online".to_owned());
                    state_errors.lock().await.remove(&id);
                    let _ = app.emit(
                        "server.snapshot",
                        SnapshotEvent {
                            server_id: id.clone(),
                            timestamp,
                            sequence,
                            payload: snapshot,
                        },
                    );
                    let _ = app.emit(
                        "server.status",
                        StatusEvent {
                            server_id: id.clone(),
                            timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
                            sequence: {
                                sequence = sequence.saturating_add(1);
                                sequence
                            },
                            payload: StatusPayload {
                                status: "online".to_owned(),
                                detail: None,
                            },
                        },
                    );
                    tokio::time::sleep(interval).await;
                }
                Err(error) => {
                    let delay = retry.register_failure(Utc::now());
                    let status = if retry.circuit_open {
                        "circuit_open".to_owned()
                    } else {
                        "offline".to_owned()
                    };
                    state_statuses.lock().await.insert(id.clone(), status.clone());
                    state_errors.lock().await.insert(id.clone(), error.public_error().detail.clone().unwrap_or_default());
                    let _ = app.emit(
                        "server.status",
                        StatusEvent {
                            server_id: id.clone(),
                            timestamp: Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
                            sequence: {
                                sequence = sequence.saturating_add(1);
                                sequence
                            },
                            payload: StatusPayload {
                                status,
                                detail: Some(error.public_error()),
                            },
                        },
                    );
                    // A small time-based jitter prevents several servers started
                    // together from reconnecting on exactly the same tick.
                    let jitter = (Utc::now().timestamp_subsec_millis() as u64) % 1000;
                    tokio::time::sleep(delay + Duration::from_millis(jitter)).await;
                }
            }
        }
    })
}

async fn start_task(
    app: AppHandle,
    state: &AppState,
    server: ServerConfig,
    interval_seconds: Option<u64>,
) -> Result<(), String> {
    server.validate().map_err(to_command_error)?;
    if !server.passwordless
        && !KeyringCredentialStore::default()
            .get(&credential_identity(&server))
            .ok()
            .flatten()
            .is_some()
    {
        return Err("password authentication requires a saved credential; choose passwordless SSH or save a password first".to_owned());
    }
    let mut tasks = state.tasks.lock().await;
    if let Some(old) = tasks.remove(&server.id) {
        old.abort();
    }
    let interval = Duration::from_secs(interval_seconds.unwrap_or(5).clamp(1, 300));
    let id = server.id.clone();
    tasks.insert(
        id,
        spawn_monitoring_task(
            app,
            state.snapshots.clone(),
            state.statuses.clone(),
            state.errors.clone(),
            server,
            interval,
        ),
    );
    Ok(())
}

#[tauri::command]
async fn list_servers() -> Result<Vec<ServerConfig>, String> {
    load_servers()
}

#[tauri::command]
async fn inspect_ssh_config() -> Result<SshConfigInfo, String> {
    let ssh = SystemOpenSsh::default();
    let path = SystemOpenSsh::config_path().map(|path| path.to_string_lossy().into_owned());
    let aliases = match ssh.discover_config_aliases() {
        Ok(aliases) => aliases,
        Err(error) => {
            return Ok(SshConfigInfo {
                path,
                aliases: Vec::new(),
                candidates: Vec::new(),
                error: Some(to_command_error(error)),
            });
        }
    };

    let mut candidates = Vec::new();
    for alias in &aliases {
        let (user, port) = match ssh.resolve_config(alias).await {
            Ok(resolved) => (Some(resolved.user), Some(resolved.port)),
            Err(_) => (None, None),
        };
        candidates.push(ServerConfig {
            id: alias.clone(),
            label: alias.clone(),
            host: alias.clone(),
            user,
            port,
            monitored: false,
            passwordless: true,
        });
    }

    Ok(SshConfigInfo {
        path,
        aliases,
        candidates,
        error: None,
    })
}

#[tauri::command]
async fn save_server(server: ServerConfig) -> Result<Vec<ServerConfig>, String> {
    server.validate().map_err(to_command_error)?;
    let (root, mut servers) = writable_servers()?;
    if let Some(existing) = servers.iter_mut().find(|existing| {
        existing.id.eq_ignore_ascii_case(&server.id)
            || existing.host.eq_ignore_ascii_case(&server.host)
    }) {
        *existing = server;
    } else {
        servers.push(server);
    }
    write_server_configs(&root, &servers).map_err(to_command_error)?;
    Ok(servers)
}

#[tauri::command]
async fn delete_server(server_id: String) -> Result<Vec<ServerConfig>, String> {
    let (root, mut servers) = writable_servers()?;
    servers.retain(|server| !server.id.eq_ignore_ascii_case(&server_id));
    write_server_configs(&root, &servers).map_err(to_command_error)?;
    Ok(servers)
}

#[tauri::command]
async fn start_monitoring(
    app: AppHandle,
    state: State<'_, AppState>,
    server: ServerConfig,
    interval_seconds: Option<u64>,
) -> Result<(), String> {
    start_task(app, &state, server, interval_seconds).await
}

#[tauri::command]
async fn stop_monitoring(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    if let Some(task) = state.tasks.lock().await.remove(&server_id) {
        task.abort();
    }
    state.statuses.lock().await.insert(server_id, "stopped".to_owned());
    Ok(())
}

#[tauri::command]
async fn recheck_monitoring(
    app: AppHandle,
    state: State<'_, AppState>,
    server: ServerConfig,
) -> Result<(), String> {
    let server_id = server.id.clone();
    if let Some(task) = state.tasks.lock().await.remove(&server_id) {
        task.abort();
    }
    state.statuses.lock().await.insert(server_id, "rechecking".to_owned());
    let interval = *state.interval_seconds.lock().await;
    start_task(app, &state, server, Some(interval)).await
}

#[tauri::command]
async fn set_all_monitoring_intervals(
    app: AppHandle,
    state: State<'_, AppState>,
    interval_seconds: u64,
) -> Result<(), String> {
    let interval = interval_seconds.clamp(1, 300);
    *state.interval_seconds.lock().await = interval;
    let _ = app.emit("interval.changed", interval);
    let servers = load_servers()?;
    for server in servers {
        if server.monitored {
            let _ = start_task(app.clone(), &state, server, Some(interval)).await;
        }
    }
    Ok(())
}

#[tauri::command]
async fn get_monitoring_state(state: State<'_, AppState>) -> Result<MonitorStateResponse, String> {
    let snapshots = state.snapshots.lock().await.clone();
    let statuses = state.statuses.lock().await.clone();
    let mut errors = state.errors.lock().await.clone();
    let interval_seconds = *state.interval_seconds.lock().await;
    for (id, status) in &statuses {
        if status == "online" {
            errors.remove(id);
        }
    }
    Ok(MonitorStateResponse {
        snapshots,
        statuses,
        errors,
        interval_seconds,
    })
}

#[tauri::command]
async fn get_data_root() -> Result<String, String> {
    Ok(DataRootManager::default().resolve().map_err(to_command_error)?.to_string_lossy().into_owned())
}

#[tauri::command]
async fn query_history(day: String) -> Result<HistoryResponse, String> {
    NaiveDate::parse_from_str(&day, "%Y-%m-%d")
        .map_err(|_| "history day must use YYYY-MM-DD".to_owned())?;
    let root = DataRootManager::default().resolve().map_err(to_command_error)?;
    let store = JsonHistoryStore::new(root);
    let path = store.history_root.join(format!("{day}.v2.jsonl"));
    let text = fs::read_to_string(path).unwrap_or_default();
    let legacy_path = store.history_root.join(format!("{day}.json"));
    let legacy = fs::read_to_string(legacy_path)
        .map(|text| serverpulse_core::read_history_json(&text))
        .unwrap_or_default();
    let read = serverpulse_core::read_history_jsonl(&text);
    let mut entries = legacy.entries;
    entries.extend(read.entries);
    Ok(HistoryResponse {
        entries,
        corrupt_lines: legacy.corrupt_lines + read.corrupt_lines,
    })
}

#[tauri::command]
async fn validate_data_root(path: String) -> Result<String, String> {
    let manager = DataRootManager::default();
    manager
        .validate_local_path(Path::new(&path), false)
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(to_command_error)
}

#[tauri::command]
async fn set_data_root(path: String) -> Result<String, String> {
    let manager = DataRootManager::default();
    let path = manager
        .validate_local_path(Path::new(&path), true)
        .map_err(to_command_error)?;
    manager
        .write_pointer(&path, &path, false)
        .map_err(to_command_error)?;
    Ok(path.to_string_lossy().into_owned())
}

#[tauri::command]
async fn save_credential(server: ServerConfig, password: String) -> Result<(), String> {
    server.validate().map_err(to_command_error)?;
    if password.is_empty() {
        return Err("password must not be empty".to_owned());
    }
    KeyringCredentialStore::default()
        .set(&credential_identity(&server), &password)
        .map_err(to_command_error)
}

#[tauri::command]
async fn delete_credential(server: ServerConfig) -> Result<(), String> {
    server.validate().map_err(to_command_error)?;
    KeyringCredentialStore::default()
        .delete(&credential_identity(&server))
        .map_err(to_command_error)
}

#[tauri::command]
async fn preview_import(source: String, target: Option<String>) -> Result<serverpulse_platform::MigrationPreview, String> {
    let manager = DataRootManager::default();
    let target = target.map(std::path::PathBuf::from).unwrap_or(manager.default_root.clone());
    manager.preview_import(std::path::Path::new(&source), &target).map_err(to_command_error)
}

#[tauri::command]
async fn apply_import(source: String, target: Option<String>, mode: ConflictMode) -> Result<serverpulse_platform::MigrationResult, String> {
    let manager = DataRootManager::default();
    let target = target.map(std::path::PathBuf::from).unwrap_or(manager.default_root.clone());
    manager.import(std::path::Path::new(&source), &target, mode).map_err(to_command_error)
}

#[tauri::command]
async fn open_window(app: AppHandle, kind: String) -> Result<(), String> {
    let (label, title) = match kind.as_str() {
        "manage" => ("manage", "SSH Servers"),
        "history" => ("history", "Usage History"),
        _ => return Err("unknown window kind".to_owned()),
    };
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.set_always_on_top(true);
        window.show().map_err(to_command_error)?;
        window.set_focus().map_err(to_command_error)?;
        return Ok(());
    }
    let (width, height) = match kind.as_str() {
        "history" => (940.0, 700.0),
        _ => (760.0, 600.0),
    };
    WebviewWindowBuilder::new(
        &app,
        label,
        WebviewUrl::App(format!("index.html?view={kind}").into()),
    )
    .title(title)
    .inner_size(width, height)
    .min_inner_size(500.0, 400.0)
    .resizable(true)
    .always_on_top(true)
    .center()
    .build()
    .map(|_| ())
    .map_err(to_command_error)
}

#[tauri::command]
async fn drag_window(window: tauri::WebviewWindow) -> Result<(), String> {
    window.start_dragging().map_err(to_command_error)
}

#[tauri::command]
async fn hide_main_window(app: AppHandle) -> Result<(), String> {
    app.get_webview_window("main")
        .ok_or_else(|| "main window is missing".to_owned())?
        .hide()
        .map_err(to_command_error)
}

#[tauri::command]
async fn close_main_window(app: AppHandle) -> Result<(), String> {
    app.get_webview_window("main")
        .ok_or_else(|| "main window is missing".to_owned())?
        .close()
        .map_err(to_command_error)
}

fn setup_tray(app: &mut tauri::App) -> tauri::Result<()> {
    let show = MenuItemBuilder::with_id("show", "Show").build(app)?;
    let hide = MenuItemBuilder::with_id("hide", "Hide").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Exit").build(app)?;
    let menu = MenuBuilder::new(app).items(&[&show, &hide, &quit]).build()?;
    TrayIconBuilder::new()
        .menu(&menu)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "hide" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.hide();
                }
            }
            "quit" => app.exit(0),
            _ => {}
        })
        .build(app)?;
    Ok(())
}

fn run_askpass_child() -> bool {
    let Ok(identity) = std::env::var("SERVERPULSE_CREDENTIAL_ID") else {
        return false;
    };
    let Ok(Some(password)) = KeyringCredentialStore::default().get(&identity) else {
        return true;
    };
    println!("{password}");
    true
}

fn main() {
    if run_askpass_child() {
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_window_state::Builder::default().build())
        .manage(AppState::default())
        .setup(|app| {
            setup_tray(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_servers,
            inspect_ssh_config,
            save_server,
            delete_server,
            start_monitoring,
            stop_monitoring,
            recheck_monitoring,
            set_all_monitoring_intervals,
            get_monitoring_state,
            get_data_root,
            validate_data_root,
            set_data_root,
            save_credential,
            delete_credential,
            query_history,
            preview_import,
            apply_import,
            open_window,
            drag_window,
            hide_main_window,
            close_main_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running Server Pulse");
}
