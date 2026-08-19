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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct EdgeDockState {
    dock_side: String, // "none" | "left" | "right" | "top"
    is_hidden: bool,
    auto_hide_enabled: bool,
    shown_x: i32,
    shown_y: i32,
    win_width: i32,
    win_height: i32,
}

impl Default for EdgeDockState {
    fn default() -> Self {
        Self {
            dock_side: "none".to_string(),
            is_hidden: false,
            auto_hide_enabled: true,
            shown_x: 0,
            shown_y: 0,
            win_width: 320,
            win_height: 480,
        }
    }
}

struct AppState {
    tasks: Arc<Mutex<HashMap<String, JoinHandle<()>>>>,
    snapshots: Arc<Mutex<HashMap<String, MetricSnapshot>>>,
    statuses: Arc<Mutex<HashMap<String, String>>>,
    errors: Arc<Mutex<HashMap<String, String>>>,
    interval_seconds: Arc<Mutex<u64>>,
    edge_dock_state: Arc<Mutex<EdgeDockState>>,
    edge_dock_enabled: Arc<std::sync::atomic::AtomicBool>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            snapshots: Arc::new(Mutex::new(HashMap::new())),
            statuses: Arc::new(Mutex::new(HashMap::new())),
            errors: Arc::new(Mutex::new(HashMap::new())),
            interval_seconds: Arc::new(Mutex::new(5)),
            edge_dock_state: Arc::new(Mutex::new(EdgeDockState::default())),
            edge_dock_enabled: Arc::new(std::sync::atomic::AtomicBool::new(true)),
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
async fn save_server(
    app: AppHandle,
    state: State<'_, AppState>,
    server: ServerConfig,
) -> Result<Vec<ServerConfig>, String> {
    server.validate().map_err(to_command_error)?;
    let (root, mut servers) = writable_servers()?;
    if let Some(existing) = servers.iter_mut().find(|existing| {
        existing.id.eq_ignore_ascii_case(&server.id)
            || existing.host.eq_ignore_ascii_case(&server.host)
    }) {
        *existing = server.clone();
    } else {
        servers.push(server.clone());
    }
    write_server_configs(&root, &servers).map_err(to_command_error)?;
    if !server.monitored {
        if let Some(task) = state.tasks.lock().await.remove(&server.id) {
            task.abort();
        }
        state.statuses.lock().await.insert(server.id.clone(), "stopped".to_owned());
    }
    let _ = app.emit("servers.changed", &servers);
    Ok(servers)
}

#[tauri::command]
async fn delete_server(
    app: AppHandle,
    state: State<'_, AppState>,
    server_id: String,
) -> Result<Vec<ServerConfig>, String> {
    let (root, mut servers) = writable_servers()?;
    servers.retain(|server| !server.id.eq_ignore_ascii_case(&server_id));
    write_server_configs(&root, &servers).map_err(to_command_error)?;
    if let Some(task) = state.tasks.lock().await.remove(&server_id) {
        task.abort();
    }
    state.snapshots.lock().await.remove(&server_id);
    state.statuses.lock().await.remove(&server_id);
    state.errors.lock().await.remove(&server_id);
    let _ = app.emit("servers.changed", &servers);
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

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct WindowMonitorBounds {
    monitor_x: i32,
    monitor_y: i32,
    monitor_width: i32,
    monitor_height: i32,
    scale_factor: f64,
    window_x: i32,
    window_y: i32,
    window_width: i32,
    window_height: i32,
}

#[tauri::command]
async fn get_window_monitor_bounds(app: AppHandle) -> Result<WindowMonitorBounds, String> {
    let window = app.get_webview_window("main").ok_or("Main window not found")?;
    let scale = window.scale_factor().unwrap_or(1.0);
    let win_pos = window.outer_position().map_err(to_command_error)?;
    let win_size = window.outer_size().map_err(to_command_error)?;

    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::Foundation::HWND;
        use windows_sys::Win32::Graphics::Gdi::{
            GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
        };
        if let Ok(hwnd) = window.hwnd() {
            unsafe {
                let hmon = MonitorFromWindow(hwnd.0 as HWND, MONITOR_DEFAULTTONEAREST);
                if !hmon.is_null() {
                    let mut mi: MONITORINFO = std::mem::zeroed();
                    mi.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
                    if GetMonitorInfoW(hmon, &mut mi) != 0 {
                        return Ok(WindowMonitorBounds {
                            monitor_x: mi.rcWork.left,
                            monitor_y: mi.rcWork.top,
                            monitor_width: mi.rcWork.right - mi.rcWork.left,
                            monitor_height: mi.rcWork.bottom - mi.rcWork.top,
                            scale_factor: scale,
                            window_x: win_pos.x,
                            window_y: win_pos.y,
                            window_width: win_size.width as i32,
                            window_height: win_size.height as i32,
                        });
                    }
                }
            }
        }
    }

    let monitor = window
        .current_monitor()
        .map_err(to_command_error)?
        .ok_or("No monitor found for window")?;
    let mon_pos = monitor.position();
    let mon_size = monitor.size();

    Ok(WindowMonitorBounds {
        monitor_x: mon_pos.x,
        monitor_y: mon_pos.y,
        monitor_width: mon_size.width as i32,
        monitor_height: mon_size.height as i32,
        scale_factor: scale,
        window_x: win_pos.x,
        window_y: win_pos.y,
        window_width: win_size.width as i32,
        window_height: win_size.height as i32,
    })
}

#[tauri::command]
async fn get_cursor_position() -> Result<(i32, i32), String> {
    #[cfg(target_os = "windows")]
    {
        use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;
        use windows_sys::Win32::Foundation::POINT;
        let mut pt = POINT { x: 0, y: 0 };
        unsafe {
            if GetCursorPos(&mut pt) != 0 {
                return Ok((pt.x, pt.y));
            }
        }
    }
    Err("Cursor position not available on this platform".to_owned())
}

#[cfg(target_os = "windows")]
fn start_edge_dock_worker(
    app: AppHandle,
    enabled: Arc<std::sync::atomic::AtomicBool>,
    state_lock: Arc<Mutex<EdgeDockState>>,
) {
    use std::sync::atomic::Ordering;
    use windows_sys::Win32::Foundation::{HWND, POINT, RECT};
    use windows_sys::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetCursorPos, GetWindowRect, IsIconic, IsWindowVisible, SetWindowPos, HWND_TOPMOST,
        SWP_SHOWWINDOW,
    };

    tauri::async_runtime::spawn(async move {
        let mut hide_countdown_ticks: i32 = 0; // Each tick = 50ms (600ms = 12 ticks)

        loop {
            tokio::time::sleep(Duration::from_millis(50)).await;

            let auto_hide_on = enabled.load(Ordering::Relaxed);

            let Some(window) = app.get_webview_window("main") else {
                continue;
            };

            let Ok(hwnd_raw) = window.hwnd() else {
                continue;
            };
            let hwnd_isize = hwnd_raw.0 as isize;

            let (visible, cur_pos, rect, work_left, work_top, work_right) = unsafe {
                let hwnd = hwnd_isize as HWND;
                if IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 {
                    (false, POINT { x: 0, y: 0 }, RECT { left: 0, top: 0, right: 0, bottom: 0 }, 0, 0, 0)
                } else {
                    let mut cur = POINT { x: 0, y: 0 };
                    GetCursorPos(&mut cur);
                    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
                    GetWindowRect(hwnd, &mut r);
                    let hmon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
                    let mut mi: MONITORINFO = std::mem::zeroed();
                    mi.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
                    if !hmon.is_null() && GetMonitorInfoW(hmon, &mut mi) != 0 {
                        (true, cur, r, mi.rcWork.left, mi.rcWork.top, mi.rcWork.right)
                    } else {
                        (false, cur, r, 0, 0, 0)
                    }
                }
            };

            if !visible {
                continue;
            }

            let win_w = rect.right - rect.left;
            let win_h = rect.bottom - rect.top;

            let mut state = state_lock.lock().await;
            state.auto_hide_enabled = auto_hide_on;

            if !auto_hide_on {
                if state.is_hidden {
                    state.is_hidden = false;
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            state.shown_x,
                            state.shown_y,
                            win_w,
                            win_h,
                            SWP_SHOWWINDOW,
                        );
                    }
                    let _ = app.emit("edge_dock_state", state.clone());
                }
                state.dock_side = "none".to_string();
                continue;
            }

            // If currently not docked:
            if state.dock_side == "none" {
                let threshold = 35;
                let left_dist = rect.left - work_left;
                let right_dist = work_right - rect.right;
                let top_dist = rect.top - work_top;

                if left_dist <= threshold && left_dist >= -win_w / 2 {
                    state.dock_side = "left".to_string();
                    state.shown_x = work_left;
                    state.shown_y = rect.top;
                    state.win_width = win_w;
                    state.win_height = win_h;
                    state.is_hidden = false;
                    hide_countdown_ticks = 12; // 600ms
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            work_left,
                            rect.top,
                            win_w,
                            win_h,
                            SWP_SHOWWINDOW,
                        );
                    }
                    let _ = app.emit("edge_dock_state", state.clone());
                } else if right_dist <= threshold && right_dist >= -win_w / 2 {
                    state.dock_side = "right".to_string();
                    state.shown_x = work_right - win_w;
                    state.shown_y = rect.top;
                    state.win_width = win_w;
                    state.win_height = win_h;
                    state.is_hidden = false;
                    hide_countdown_ticks = 12;
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            work_right - win_w,
                            rect.top,
                            win_w,
                            win_h,
                            SWP_SHOWWINDOW,
                        );
                    }
                    let _ = app.emit("edge_dock_state", state.clone());
                } else if top_dist <= threshold && top_dist >= -win_h / 2 {
                    state.dock_side = "top".to_string();
                    state.shown_x = rect.left;
                    state.shown_y = work_top;
                    state.win_width = win_w;
                    state.win_height = win_h;
                    state.is_hidden = false;
                    hide_countdown_ticks = 12;
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            rect.left,
                            work_top,
                            win_w,
                            win_h,
                            SWP_SHOWWINDOW,
                        );
                    }
                    let _ = app.emit("edge_dock_state", state.clone());
                }
                continue;
            }

            // If currently docked:
            if !state.is_hidden {
                // Check if dragged away from edge (> 40px)
                let moved_away = match state.dock_side.as_str() {
                    "left" => (rect.left - work_left).abs() > 40,
                    "right" => (work_right - rect.right).abs() > 40,
                    "top" => (rect.top - work_top).abs() > 40,
                    _ => false,
                };
                if moved_away {
                    state.dock_side = "none".to_string();
                    state.is_hidden = false;
                    let _ = app.emit("edge_dock_state", state.clone());
                    continue;
                }

                // Check if cursor is inside shown window
                let inside = cur_pos.x >= state.shown_x
                    && cur_pos.x <= state.shown_x + state.win_width
                    && cur_pos.y >= state.shown_y
                    && cur_pos.y <= state.shown_y + state.win_height;

                if inside {
                    hide_countdown_ticks = 12; // 600ms
                } else if hide_countdown_ticks > 0 {
                    hide_countdown_ticks -= 1;
                } else {
                    // Hide!
                    state.is_hidden = true;
                    let _ = app.emit("edge_dock_state", state.clone());
                    tokio::time::sleep(Duration::from_millis(30)).await;

                    let handle_px = 16;
                    let (to_x, to_y) = match state.dock_side.as_str() {
                        "left" => (work_left - state.win_width + handle_px, state.shown_y),
                        "right" => (work_right - handle_px, state.shown_y),
                        "top" => (state.shown_x, work_top - state.win_height + handle_px),
                        _ => (state.shown_x, state.shown_y),
                    };

                    let from_x = rect.left;
                    let from_y = rect.top;
                    let steps = 8;
                    for i in 1..=steps {
                        let prog = i as f64 / steps as f64;
                        let ease = 1.0 - (1.0 - prog).powi(2);
                        let cx = from_x + ((to_x - from_x) as f64 * ease).round() as i32;
                        let cy = from_y + ((to_y - from_y) as f64 * ease).round() as i32;
                        unsafe {
                            SetWindowPos(
                                hwnd_isize as HWND,
                                HWND_TOPMOST,
                                cx,
                                cy,
                                state.win_width,
                                state.win_height,
                                SWP_SHOWWINDOW,
                            );
                        }
                        tokio::time::sleep(Duration::from_millis(15)).await;
                    }
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            to_x,
                            to_y,
                            state.win_width,
                            state.win_height,
                            SWP_SHOWWINDOW,
                        );
                    }
                }
            } else {
                // Window is hidden! Check if cursor touches dock edge
                let trigger_px = 24;
                let touches = match state.dock_side.as_str() {
                    "right" => {
                        cur_pos.x >= work_right - trigger_px
                            && cur_pos.y >= state.shown_y - 30
                            && cur_pos.y <= state.shown_y + state.win_height + 30
                    }
                    "left" => {
                        cur_pos.x <= work_left + trigger_px
                            && cur_pos.y >= state.shown_y - 30
                            && cur_pos.y <= state.shown_y + state.win_height + 30
                    }
                    "top" => {
                        cur_pos.y <= work_top + trigger_px
                            && cur_pos.x >= state.shown_x - 30
                            && cur_pos.x <= state.shown_x + state.win_width + 30
                    }
                    _ => false,
                };

                if touches {
                    // Reveal!
                    state.is_hidden = false;
                    hide_countdown_ticks = 16; // 800ms
                    let _ = app.emit("edge_dock_state", state.clone());

                    let from_x = rect.left;
                    let from_y = rect.top;
                    let to_x = state.shown_x;
                    let to_y = state.shown_y;
                    let steps = 8;
                    for i in 1..=steps {
                        let prog = i as f64 / steps as f64;
                        let ease = 1.0 - (1.0 - prog).powi(2);
                        let cx = from_x + ((to_x - from_x) as f64 * ease).round() as i32;
                        let cy = from_y + ((to_y - from_y) as f64 * ease).round() as i32;
                        unsafe {
                            SetWindowPos(
                                hwnd_isize as HWND,
                                HWND_TOPMOST,
                                cx,
                                cy,
                                state.win_width,
                                state.win_height,
                                SWP_SHOWWINDOW,
                            );
                        }
                        tokio::time::sleep(Duration::from_millis(15)).await;
                    }
                    unsafe {
                        SetWindowPos(
                            hwnd_isize as HWND,
                            HWND_TOPMOST,
                            to_x,
                            to_y,
                            state.win_width,
                            state.win_height,
                            SWP_SHOWWINDOW,
                        );
                    }
                }
            }
        }
    });
}

#[tauri::command]
async fn get_edge_dock_state(state: State<'_, AppState>) -> Result<EdgeDockState, String> {
    let s = state.edge_dock_state.lock().await;
    Ok(s.clone())
}

#[tauri::command]
async fn set_edge_dock_autohide(
    state: State<'_, AppState>,
    app: AppHandle,
    enabled: bool,
) -> Result<EdgeDockState, String> {
    use std::sync::atomic::Ordering;
    state.edge_dock_enabled.store(enabled, Ordering::Relaxed);
    let mut s = state.edge_dock_state.lock().await;
    s.auto_hide_enabled = enabled;
    let _ = app.emit("edge_dock_state", s.clone());
    Ok(s.clone())
}

#[tauri::command]
async fn toggle_edge_dock_autohide(
    state: State<'_, AppState>,
    app: AppHandle,
) -> Result<EdgeDockState, String> {
    use std::sync::atomic::Ordering;
    let prev = state.edge_dock_enabled.load(Ordering::Relaxed);
    let new_val = !prev;
    state.edge_dock_enabled.store(new_val, Ordering::Relaxed);
    let mut s = state.edge_dock_state.lock().await;
    s.auto_hide_enabled = new_val;
    let _ = app.emit("edge_dock_state", s.clone());
    Ok(s.clone())
}

#[tauri::command]
async fn set_main_window_position(app: AppHandle, x: i32, y: i32) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("Main window not found")?;
    window
        .set_position(tauri::Position::Physical(tauri::PhysicalPosition { x, y }))
        .map_err(to_command_error)?;
    Ok(())
}

#[tauri::command]
async fn animate_main_window_position(
    app: AppHandle,
    from_x: i32,
    from_y: i32,
    to_x: i32,
    to_y: i32,
    duration_ms: u64,
) -> Result<(), String> {
    let window = app.get_webview_window("main").ok_or("Main window not found")?;
    let steps = 15;
    let step_delay = Duration::from_millis((duration_ms / steps as u64).max(1));
    for i in 1..=steps {
        let progress = i as f64 / steps as f64;
        let ease = 1.0 - (1.0 - progress).powi(3);
        let curr_x = from_x + ((to_x - from_x) as f64 * ease).round() as i32;
        let curr_y = from_y + ((to_y - from_y) as f64 * ease).round() as i32;
        let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition { x: curr_x, y: curr_y }));
        tokio::time::sleep(step_delay).await;
    }
    let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition { x: to_x, y: to_y }));
    Ok(())
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
    let show = MenuItemBuilder::with_id("show", "Show Server Pulse").build(app)?;
    let hide = MenuItemBuilder::with_id("hide", "Hide to Tray").build(app)?;
    let servers = MenuItemBuilder::with_id("servers", "SSH Servers...").build(app)?;
    let history = MenuItemBuilder::with_id("history", "History...").build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Exit").build(app)?;
    let menu = MenuBuilder::new(app)
        .items(&[&show, &hide, &servers, &history, &quit])
        .build()?;
    TrayIconBuilder::new()
        .tooltip("Server Pulse")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_tray_icon_event(|tray, event| {
            if let tauri::tray::TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let is_visible = window.is_visible().unwrap_or(false);
                    if is_visible {
                        let _ = window.set_focus();
                    } else {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
            }
        })
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                    let _ = window.set_focus();
                }
            }
            "servers" => {
                let _ = open_window(app.clone(), "manage".to_string());
            }
            "history" => {
                let _ = open_window(app.clone(), "history".to_string());
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
            if let Some(main_win) = app.get_webview_window("main") {
                let _ = main_win.set_skip_taskbar(true);
            }
            #[cfg(target_os = "windows")]
            {
                let state = app.state::<AppState>();
                start_edge_dock_worker(
                    app.handle().clone(),
                    state.edge_dock_enabled.clone(),
                    state.edge_dock_state.clone(),
                );
            }
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
            close_main_window,
            get_window_monitor_bounds,
            get_cursor_position,
            set_main_window_position,
            animate_main_window_position,
            get_edge_dock_state,
            set_edge_dock_autohide,
            toggle_edge_dock_autohide
        ])
        .run(tauri::generate_context!())
        .expect("error while running Server Pulse");
}
