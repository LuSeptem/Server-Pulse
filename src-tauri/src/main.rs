#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use chrono::{NaiveDate, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serverpulse_core::{AppError, MetricSnapshot, RetryState, ServerConfig};
use serverpulse_platform::{
    read_server_configs, write_server_configs, ConflictMode, CredentialStore, DataRootManager,
    JsonHistoryStore, KeyringCredentialStore,
};
use serverpulse_ssh::{
    HostKeyChallenge, HostKeyState, KnownHostsManager, ScannedHostKey, SshStream, SshTarget,
    SshTransport, SystemOpenSsh,
};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tokio::sync::{oneshot, Mutex};
use tokio::task::JoinHandle;

mod session_credentials;
use session_credentials::SessionCredentialBroker;

const SAMPLE_SCRIPT: &str = include_str!("../../assets/serverpulse-sample.sh");
const SCAN_SCRIPT: &str = include_str!("../../assets/serverpulse-scan.sh");
const SEED_SERVERS: &str = include_str!("../../config/servers.json");
const AGENT_PULL_TIMEOUT: Duration = Duration::from_secs(120);

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
    tasks: Arc<Mutex<HashMap<String, MonitoringTask>>>,
    snapshots: Arc<Mutex<HashMap<String, MetricSnapshot>>>,
    statuses: Arc<Mutex<HashMap<String, String>>>,
    errors: Arc<Mutex<HashMap<String, String>>>,
    session_credentials: SessionCredentialBroker,
    pending_host_keys: Arc<Mutex<HashMap<String, PendingHostKey>>>,
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
            session_credentials: SessionCredentialBroker::default(),
            pending_host_keys: Arc::new(Mutex::new(HashMap::new())),
            interval_seconds: Arc::new(Mutex::new(5)),
            edge_dock_state: Arc::new(Mutex::new(EdgeDockState::default())),
            edge_dock_enabled: Arc::new(std::sync::atomic::AtomicBool::new(true)),
        }
    }
}

struct MonitoringTask {
    join: JoinHandle<()>,
    cancel: oneshot::Sender<()>,
}

struct PendingHostKey {
    server: ServerConfig,
    target: SshTarget,
    scanned: Vec<ScannedHostKey>,
    challenge: HostKeyChallenge,
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
struct StartResult {
    server_id: String,
    status: String,
    detail: Option<String>,
    host_key: Option<HostKeyChallenge>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct VerifyAndApplyRequest {
    server: ServerConfig,
    password: Option<String>,
    save_password: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct ApplyServerResult {
    servers: Vec<ServerConfig>,
    start: StartResult,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct HistoryResponse {
    entries: Vec<serverpulse_core::HistoryEntry>,
    corrupt_lines: usize,
    disk_attribution: Vec<serverpulse_core::DiskAttributionRecord>,
}

/// Lightweight response for windows that only poll disk attribution. Reads
/// the small attribution files instead of the full history day files, so the
/// periodic auto-refresh never materializes hundreds of MB of metric records.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DiskAttributionResponse {
    disk_attribution: Vec<serverpulse_core::DiskAttributionRecord>,
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

    let repository_seed = std::env::current_dir()
        .map_err(to_command_error)?
        .join("config/servers.json");
    if repository_seed.exists() {
        return parse_servers(&fs::read_to_string(repository_seed).map_err(to_command_error)?);
    }
    parse_servers(SEED_SERVERS)
}

fn writable_servers() -> Result<(std::path::PathBuf, Vec<ServerConfig>), String> {
    let root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let servers = read_server_configs(&root)
        .map_err(to_command_error)?
        .unwrap_or_else(discovered_servers);
    Ok((root, servers))
}

/// Append one sanitized, timestamped line to `<data-root>/error.log`.
/// Best-effort: logging failures never propagate to callers.
fn append_error_log(data_root: &Path, message: &str) {
    let sanitized = message.replace(['\r', '\n', '\t'], " ");
    let line = format!(
        "[{}] {}",
        Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true),
        sanitized
    );
    let path = data_root.join("error.log");
    if let Ok(mut file) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        use std::io::Write as _;
        let _ = writeln!(file, "{line}");
    }
}

fn history_line(
    server: &ServerConfig,
    timestamp: &str,
    snapshot: &MetricSnapshot,
) -> Result<String, String> {
    let gpus_json: Vec<serde_json::Value> = snapshot
        .gpus
        .iter()
        .map(|gpu| {
            serde_json::json!({
                "Index": gpu.index,
                "ValidSamples": 1,
                "Name": gpu.name,
                "Uuid": gpu.uuid,
                "Utilization": gpu.utilization,
                "MemoryUsedMiB": gpu.memory_used_mib,
                "MemoryTotalMiB": gpu.memory_total_mib,
                "TemperatureC": gpu.temperature_c,
                "PowerDrawW": gpu.power_draw_w,
                "PowerLimitW": gpu.power_limit_w,
                "FanPercent": gpu.fan_percent,
                "UserMemory": {
                    "Status": match gpu.user_memory_status {
                        serverpulse_core::UserUsageStatus::Ok => "ok",
                        serverpulse_core::UserUsageStatus::Partial => "partial",
                        serverpulse_core::UserUsageStatus::Unavailable => "unavailable",
                    },
                    "ValidSamples": 1,
                    "Users": gpu.user_memory.iter().map(|u| {
                        serde_json::json!({
                            "Uid": u.uid,
                            "Name": u.name,
                            "UsedMiB": u.used_mib,
                            "Percent": u.percent,
                        })
                    }).collect::<Vec<_>>(),
                    "UnmappedProcesses": gpu.unmapped_processes,
                },
            })
        })
        .collect();

    let disks_json: Vec<serde_json::Value> = snapshot
        .disks
        .iter()
        .map(|disk| {
            serde_json::json!({
                "Mount": disk.mount,
                "Percent": disk.percent,
                "TotalMiB": disk.total_mib,
                "UsedMiB": disk.used_mib,
            })
        })
        .collect();

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
                "CpuUserUsage": {
                    "Status": match snapshot.cpu_user_status {
                        serverpulse_core::UserUsageStatus::Ok => "ok",
                        serverpulse_core::UserUsageStatus::Partial => "partial",
                        serverpulse_core::UserUsageStatus::Unavailable => "unavailable",
                    },
                    "ValidSamples": 1,
                    "Users": snapshot.cpu_users.iter().map(|u| {
                        serde_json::json!({
                            "Uid": u.uid,
                            "Name": u.name,
                            "Percent": u.percent,
                        })
                    }).collect::<Vec<_>>(),
                },
                "MemoryUsedMiB": snapshot.memory_used_mib,
                "MemoryTotalMiB": snapshot.memory_total_mib,
                "MemoryPercent": snapshot.memory_percent,
                "MemoryUserUsage": {
                    "Status": match snapshot.memory_user_status {
                        serverpulse_core::UserUsageStatus::Ok => "ok",
                        serverpulse_core::UserUsageStatus::Partial => "partial",
                        serverpulse_core::UserUsageStatus::Unavailable => "unavailable",
                    },
                    "ValidSamples": 1,
                    "Users": snapshot.memory_users.iter().map(|u| {
                        serde_json::json!({
                            "Uid": u.uid,
                            "Name": u.name,
                            "UsedMiB": u.used_mib,
                            "Percent": u.percent,
                        })
                    }).collect::<Vec<_>>(),
                },
                "LoadOne": snapshot.load_one,
                "LoadFive": snapshot.load_five,
                "LoadFifteen": snapshot.load_fifteen,
                "UptimeSeconds": snapshot.uptime_seconds,
                "Gpus": gpus_json,
                "Disks": disks_json,
            }]
        }
    }))
    .map_err(to_command_error)
}

#[cfg(test)]
mod history_line_tests {
    use super::*;

    #[test]
    fn history_line_includes_disks_subset() {
        let server = ServerConfig {
            id: "s1".to_owned(),
            label: "S1".to_owned(),
            host: "s1".to_owned(),
            user: None,
            port: None,
            monitored: true,
            passwordless: true,
        };
        let snapshot_json = r#"{"hostname":"demo","protocolVersion":2,"cpuPercent":1.0,"memoryTotalMib":10,"memoryUsedMib":5,"memoryPercent":50,"loadOne":null,"loadFive":null,"loadFifteen":null,"uptimeSeconds":null,"cpuUserStatus":"unavailable","cpuUsers":[],"memoryUserStatus":"unavailable","memoryUsers":[],"gpus":[],"disks":[{"device":"/dev/sda1","mount":"/data","totalMib":1000.0,"usedMib":250.0,"percent":25.0,"fsType":"xfs"}]}"#;
        let snapshot: MetricSnapshot = serde_json::from_str(snapshot_json).unwrap();
        let line = history_line(&server, "2026-08-21T00:00:00Z", &snapshot).unwrap();
        assert!(line.contains("\"Disks\":[{\"Mount\":\"/data\",\"Percent\":25.0,\"TotalMiB\":1000.0,\"UsedMiB\":250.0}]"));
    }

    #[test]
    fn history_line_without_disks_omits_entries() {
        let server = ServerConfig {
            id: "s1".to_owned(),
            label: "S1".to_owned(),
            host: "s1".to_owned(),
            user: None,
            port: None,
            monitored: true,
            passwordless: true,
        };
        let snapshot_json = r#"{"hostname":"demo","protocolVersion":2,"cpuPercent":1.0,"memoryTotalMib":10,"memoryUsedMib":5,"memoryPercent":50,"loadOne":null,"loadFive":null,"loadFifteen":null,"uptimeSeconds":null,"cpuUserStatus":"unavailable","cpuUsers":[],"memoryUserStatus":"unavailable","memoryUsers":[],"gpus":[],"disks":[]}"#;
        let snapshot: MetricSnapshot = serde_json::from_str(snapshot_json).unwrap();
        let line = history_line(&server, "2026-08-21T00:00:00Z", &snapshot).unwrap();
        assert!(line.contains("\"Disks\":[]"));
    }
}

fn credential_identity(server: &ServerConfig) -> String {
    format!(
        "{}@{}:{}",
        server.user.as_deref().unwrap_or("default"),
        server.host,
        server.port.unwrap_or(22)
    )
}

fn local_day_utc_range(
    target_date: NaiveDate,
) -> Result<(chrono::DateTime<Utc>, chrono::DateTime<Utc>), String> {
    let start = target_date
        .and_time(chrono::NaiveTime::MIN)
        .and_local_timezone(chrono::Local)
        .earliest()
        .unwrap_or_else(|| {
            target_date
                .and_time(chrono::NaiveTime::MIN)
                .and_utc()
                .with_timezone(&chrono::Local)
        });
    let next_date = target_date
        .succ_opt()
        .ok_or_else(|| "history day is out of range".to_owned())?;
    let end = next_date
        .and_time(chrono::NaiveTime::MIN)
        .and_local_timezone(chrono::Local)
        .earliest()
        .unwrap_or_else(|| {
            next_date
                .and_time(chrono::NaiveTime::MIN)
                .and_utc()
                .with_timezone(&chrono::Local)
        });
    Ok((start.with_timezone(&Utc), end.with_timezone(&Utc)))
}

/// Candidate UTC day files plus the exact half-open UTC window for a local
/// calendar date. Shared by the full history query and the lightweight
/// disk-attribution query.
fn history_query_window(
    target_date: NaiveDate,
) -> Result<(Vec<String>, chrono::DateTime<Utc>, chrono::DateTime<Utc>), String> {
    let (utc_start, utc_end) = local_day_utc_range(target_date)?;
    let mut candidate_days = Vec::new();
    let mut cursor = utc_start
        .date_naive()
        .pred_opt()
        .unwrap_or(utc_start.date_naive());
    let last_day = utc_end
        .date_naive()
        .succ_opt()
        .unwrap_or(utc_end.date_naive());
    while cursor <= last_day {
        candidate_days.push(cursor.format("%Y-%m-%d").to_string());
        let Some(next) = cursor.succ_opt() else { break };
        cursor = next;
    }
    Ok((candidate_days, utc_start, utc_end))
}

fn utc_history_bucket(now: chrono::DateTime<Utc>) -> (String, String) {
    (
        now.to_rfc3339_opts(SecondsFormat::Secs, true),
        now.format("%Y-%m-%d").to_string(),
    )
}

/// Minute key for history throttling: at most one recorded sample per server
/// per UTC minute regardless of the live sampling interval. Reconnects reset
/// the slot, which can rarely emit two lines in one minute; the query-side
/// dedup absorbs that.
fn should_record_history_minute(slot: &mut Option<String>, history_timestamp: &str) -> bool {
    let minute_key = history_timestamp
        .get(..16)
        .unwrap_or(history_timestamp)
        .to_owned();
    if slot.as_deref() == Some(minute_key.as_str()) {
        return false;
    }
    *slot = Some(minute_key);
    true
}

fn known_hosts_manager() -> Result<KnownHostsManager, String> {
    let root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    Ok(KnownHostsManager::new(
        root.join("known_hosts"),
        KnownHostsManager::user_known_hosts_path(),
    ))
}

fn target_with_known_hosts(server: &ServerConfig) -> Result<SshTarget, String> {
    let manager = known_hosts_manager()?;
    let mut target = SshTarget::from_server(server);
    target.known_hosts_file = Some(manager.paths.application);
    target.user_known_hosts_file = manager.paths.user;
    Ok(target)
}

async fn resolved_host_key_target(server: &ServerConfig) -> Result<SshTarget, String> {
    let mut target = target_with_known_hosts(server)?;
    let resolved = SystemOpenSsh::default()
        .resolve_target(&target)
        .await
        .map_err(to_command_error)?;
    target.resolved_host = Some(resolved.host_name);
    target.resolved_port = Some(resolved.port);
    Ok(target)
}

async fn target_with_credentials(
    server: &ServerConfig,
    state: &AppState,
) -> Result<SshTarget, String> {
    let mut target = target_with_known_hosts(server)?;
    if server.passwordless {
        return Ok(target);
    }
    if let Some(password) = state.session_credentials.password(&server.id).await {
        let handle = match state
            .session_credentials
            .prepare_listener(&server.id, &password)
            .await
        {
            Ok(handle) => handle,
            Err(error) => {
                state.session_credentials.clear(&server.id).await;
                return Err(error);
            }
        };
        target.session_credential_token = Some(handle.token);
        target.session_credential_endpoint = Some(handle.endpoint);
    } else {
        let identity = credential_identity(server);
        if KeyringCredentialStore::default()
            .get(&identity)
            .ok()
            .flatten()
            .is_some()
        {
            target.credential_identity = Some(identity);
        }
    }
    Ok(target)
}

async fn probe_host_key_internal(
    state: &AppState,
    server: &ServerConfig,
) -> Result<(HostKeyChallenge, SshTarget, Vec<ScannedHostKey>), String> {
    server.validate().map_err(to_command_error)?;
    let target = resolved_host_key_target(server).await?;
    let manager = known_hosts_manager()?;
    let challenge_id = uuid::Uuid::new_v4().to_string();
    let scanned = manager.scan(&target).await.map_err(to_command_error)?;
    let host_state = manager
        .classify(&target, &scanned)
        .map_err(to_command_error)?;
    let challenge = HostKeyChallenge {
        challenge_id,
        server: server.host.clone(),
        port: target.resolved_port.or(target.port).unwrap_or(22),
        keys: scanned
            .iter()
            .map(|key| serverpulse_ssh::HostKeyRecord {
                algorithm: key.algorithm.clone(),
                fingerprint: key.fingerprint.clone(),
            })
            .collect(),
        state: host_state.clone(),
    };
    let mut pending = state.pending_host_keys.lock().await;
    if host_state == HostKeyState::Trusted {
        pending.retain(|_, value| value.server.id != server.id);
    } else {
        pending.insert(
            challenge.challenge_id.clone(),
            PendingHostKey {
                server: server.clone(),
                target: target.clone(),
                scanned: scanned.clone(),
                challenge: challenge.clone(),
            },
        );
    }
    Ok((challenge, target, scanned))
}

async fn host_key_gate(
    app: &AppHandle,
    state: &AppState,
    server: &ServerConfig,
) -> Result<Option<StartResult>, String> {
    let (challenge, _, _) = probe_host_key_internal(state, server).await?;
    if challenge.state == HostKeyState::Trusted {
        return Ok(None);
    }
    let status = if challenge.state == HostKeyState::Changed {
        "host-key-changed"
    } else {
        "host-key-required"
    };
    let result = StartResult {
        server_id: server.id.clone(),
        status: status.to_owned(),
        detail: Some(if challenge.state == HostKeyState::Changed {
            "The host key changed. Forget the application key and verify it again.".to_owned()
        } else {
            "Verify the host fingerprint before connecting.".to_owned()
        }),
        host_key: Some(challenge.clone()),
    };
    let _ = app.emit("server.host_key_required", challenge);
    Ok(Some(result))
}

fn spawn_monitoring_task(
    app: AppHandle,
    state_snapshots: Arc<Mutex<HashMap<String, MetricSnapshot>>>,
    state_statuses: Arc<Mutex<HashMap<String, String>>>,
    state_errors: Arc<Mutex<HashMap<String, String>>>,
    session_credentials: SessionCredentialBroker,
    server: ServerConfig,
    target: SshTarget,
    interval: Duration,
) -> (JoinHandle<()>, oneshot::Sender<()>) {
    let (cancel, mut cancellation) = oneshot::channel();
    let join = tokio::spawn(async move {
        let ssh = SystemOpenSsh::default();
        let id = server.id.clone();
        let data_root = DataRootManager::default().resolve().ok();
        let history_store = data_root.as_ref().map(|root| JsonHistoryStore::new(root));
        let mut sequence = 0u64;
        let mut retry = RetryState::default();
        let mut stream: Option<SshStream> = None;
        // Minute-level history throttle slot: live snapshots keep flowing at
        // the configured interval, but at most one line per server per UTC
        // minute reaches the history file.
        let mut last_history_minute: Option<String> = None;
        state_statuses
            .lock()
            .await
            .insert(id.clone(), "connecting".to_owned());
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
            if stream.is_none() {
                match ssh.open_stream(&target, SAMPLE_SCRIPT, interval).await {
                    Ok(new_stream) => {
                        stream = Some(new_stream);
                        retry.reset();
                    }
                    Err(error) => {
                        let public = error.public_error();
                        if matches!(error, serverpulse_core::ServerPulseError::Authentication(_)) {
                            session_credentials.clear(&id).await;
                            state_statuses
                                .lock()
                                .await
                                .insert(id.clone(), "authentication_failed".to_owned());
                            state_errors
                                .lock()
                                .await
                                .insert(id.clone(), public.detail.clone().unwrap_or_default());
                            let _ = app.emit(
                                "server.status",
                                StatusEvent {
                                    server_id: id.clone(),
                                    timestamp: Utc::now()
                                        .to_rfc3339_opts(SecondsFormat::Secs, true),
                                    sequence: {
                                        sequence = sequence.saturating_add(1);
                                        sequence
                                    },
                                    payload: StatusPayload {
                                        status: "authentication_failed".to_owned(),
                                        detail: Some(public),
                                    },
                                },
                            );
                            break;
                        }
                        let delay = retry.register_failure(Utc::now());
                        state_statuses
                            .lock()
                            .await
                            .insert(id.clone(), "offline".to_owned());
                        state_errors
                            .lock()
                            .await
                            .insert(id.clone(), public.detail.clone().unwrap_or_default());
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
                                    status: "offline".to_owned(),
                                    detail: Some(public),
                                },
                            },
                        );
                        tokio::select! {
                            _ = &mut cancellation => break,
                            _ = tokio::time::sleep(delay) => {}
                        }
                        continue;
                    }
                }
            }

            let result = {
                let active = stream.as_mut().expect("stream opened");
                tokio::select! {
                    _ = &mut cancellation => None,
                    value = active.next_snapshot() => Some(value),
                }
            };
            let Some(result) = result else {
                if let Some(active) = stream.take() {
                    let _ = active.shutdown().await;
                }
                break;
            };
            match result {
                Ok(snapshot) => {
                    retry.reset();
                    sequence = sequence.saturating_add(1);
                    let now_utc = Utc::now();
                    let event_timestamp = now_utc.to_rfc3339_opts(SecondsFormat::Secs, true);
                    let (history_timestamp, utc_day) = utc_history_bucket(now_utc);
                    if let (Some(store), Ok(line)) = (
                        &history_store,
                        history_line(&server, &history_timestamp, &snapshot),
                    ) {
                        if should_record_history_minute(
                            &mut last_history_minute,
                            &history_timestamp,
                        ) {
                            let _ = store.append_jsonl(&utc_day, &line);
                        }
                    }
                    state_snapshots
                        .lock()
                        .await
                        .insert(id.clone(), snapshot.clone());
                    state_statuses
                        .lock()
                        .await
                        .insert(id.clone(), "online".to_owned());
                    state_errors.lock().await.remove(&id);
                    let _ = app.emit(
                        "server.snapshot",
                        SnapshotEvent {
                            server_id: id.clone(),
                            timestamp: event_timestamp,
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
                }
                Err(error) => {
                    if let Some(active) = stream.take() {
                        let _ = active.shutdown().await;
                    }
                    let public = error.public_error();
                    if matches!(error, serverpulse_core::ServerPulseError::Authentication(_)) {
                        session_credentials.clear(&id).await;
                        state_statuses
                            .lock()
                            .await
                            .insert(id.clone(), "authentication_failed".to_owned());
                        state_errors
                            .lock()
                            .await
                            .insert(id.clone(), public.detail.clone().unwrap_or_default());
                        break;
                    }
                    let delay = retry.register_failure(Utc::now());
                    let status = if retry.circuit_open {
                        "circuit_open"
                    } else {
                        "offline"
                    }
                    .to_owned();
                    state_statuses
                        .lock()
                        .await
                        .insert(id.clone(), status.clone());
                    state_errors
                        .lock()
                        .await
                        .insert(id.clone(), public.detail.clone().unwrap_or_default());
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
                                detail: Some(public),
                            },
                        },
                    );
                    // A small time-based jitter prevents several servers started
                    // together from reconnecting on exactly the same tick.
                    let jitter = (Utc::now().timestamp_subsec_millis() as u64) % 1000;
                    tokio::select! {
                        _ = &mut cancellation => break,
                        _ = tokio::time::sleep(delay + Duration::from_millis(jitter)) => {}
                    }
                }
            }
        }
    });
    (join, cancel)
}

async fn stop_task(state: &AppState, server_id: &str, clear_credentials: bool) {
    if let Some(task) = state.tasks.lock().await.remove(server_id) {
        let MonitoringTask { join, cancel } = task;
        let _ = cancel.send(());
        await_monitoring_task(join).await;
    }
    if clear_credentials {
        state.session_credentials.clear(server_id).await;
    }
}

async fn await_monitoring_task(mut join: JoinHandle<()>) {
    if tokio::time::timeout(Duration::from_secs(2), &mut join)
        .await
        .is_err()
    {
        join.abort();
        let _ = join.await;
    }
}

async fn start_task(
    app: AppHandle,
    state: &AppState,
    server: ServerConfig,
    interval_seconds: Option<u64>,
) -> Result<StartResult, String> {
    server.validate().map_err(to_command_error)?;
    // Replacing a sampler (including an interval change) always closes the
    // previous SSH process before probing or opening the new session.
    stop_task(state, &server.id, false).await;
    if let Some(result) = host_key_gate(&app, state, &server).await? {
        return Ok(result);
    }
    let target = target_with_credentials(&server, state).await?;
    if !server.passwordless
        && target.credential_identity.is_none()
        && target.session_credential_token.is_none()
    {
        return Ok(StartResult {
            server_id: server.id.clone(),
            status: "password-required".to_owned(),
            detail: Some(
                "Enter a password for this session or save one in the OS credential store."
                    .to_owned(),
            ),
            host_key: None,
        });
    }
    let mut tasks = state.tasks.lock().await;
    let interval = Duration::from_secs(interval_seconds.unwrap_or(5).clamp(1, 300));
    let id = server.id.clone();
    let (join, cancel) = spawn_monitoring_task(
        app,
        state.snapshots.clone(),
        state.statuses.clone(),
        state.errors.clone(),
        state.session_credentials.clone(),
        server,
        target,
        interval,
    );
    tasks.insert(id.clone(), MonitoringTask { join, cancel });
    Ok(StartResult {
        server_id: id,
        status: "started".to_owned(),
        detail: None,
        host_key: None,
    })
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
async fn probe_host_key(
    state: State<'_, AppState>,
    server: ServerConfig,
) -> Result<HostKeyChallenge, String> {
    let (challenge, _, _) = probe_host_key_internal(&state, &server).await?;
    Ok(challenge)
}

#[tauri::command]
async fn accept_host_key(state: State<'_, AppState>, challenge_id: String) -> Result<(), String> {
    let pending = state
        .pending_host_keys
        .lock()
        .await
        .get(&challenge_id)
        .map(|value| PendingHostKey {
            server: value.server.clone(),
            target: value.target.clone(),
            scanned: value.scanned.clone(),
            challenge: value.challenge.clone(),
        })
        .ok_or_else(|| "host key challenge expired; probe the server again".to_owned())?;
    let manager = known_hosts_manager()?;
    manager
        .accept(&pending.target, &pending.scanned)
        .map_err(to_command_error)?;
    state.pending_host_keys.lock().await.remove(&challenge_id);
    Ok(())
}

#[tauri::command]
async fn forget_host_key(state: State<'_, AppState>, server: ServerConfig) -> Result<(), String> {
    let target = resolved_host_key_target(&server).await?;
    known_hosts_manager()?
        .forget(&target)
        .map_err(to_command_error)?;
    state
        .pending_host_keys
        .lock()
        .await
        .retain(|_, pending| pending.server.id != server.id);
    Ok(())
}

async fn persist_server(
    app: &AppHandle,
    state: &AppState,
    server: &ServerConfig,
) -> Result<Vec<ServerConfig>, String> {
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
        stop_task(state, &server.id, false).await;
        state
            .statuses
            .lock()
            .await
            .insert(server.id.clone(), "stopped".to_owned());
    }
    let _ = app.emit("servers.changed", &servers);
    Ok(servers)
}

#[tauri::command]
async fn verify_and_apply_server(
    app: AppHandle,
    state: State<'_, AppState>,
    request: VerifyAndApplyRequest,
) -> Result<ApplyServerResult, String> {
    let VerifyAndApplyRequest {
        server,
        password,
        save_password,
    } = request;
    let password = password.map(zeroize::Zeroizing::new);
    server.validate().map_err(to_command_error)?;
    let server_id = server.id.clone();
    let has_new_session_password =
        !server.passwordless && password.as_deref().is_some_and(|value| !value.is_empty());
    if server.passwordless {
        state.session_credentials.clear(&server.id).await;
    } else if let Some(password) = password.as_deref().filter(|value| !value.is_empty()) {
        state.session_credentials.set(&server.id, password).await;
    }
    let result = async {
        let host_key_result = host_key_gate(&app, &state, &server).await?;
        if let Some(result) = host_key_result {
            return Ok(ApplyServerResult {
                servers: load_servers()?,
                start: result,
            });
        }
        if save_password && !server.passwordless {
            if let Some(password) = password.as_deref().filter(|value| !value.is_empty()) {
                KeyringCredentialStore::default()
                    .set(&credential_identity(&server), password)
                    .map_err(to_command_error)?;
            } else if let Some(password) = state.session_credentials.password(&server.id).await {
                KeyringCredentialStore::default()
                    .set(&credential_identity(&server), &password)
                    .map_err(to_command_error)?;
            }
        }
        if !server.passwordless
            && state
                .session_credentials
                .password(&server.id)
                .await
                .is_none()
            && KeyringCredentialStore::default()
                .get(&credential_identity(&server))
                .ok()
                .flatten()
                .is_none()
        {
            return Ok(ApplyServerResult {
                servers: load_servers()?,
                start: StartResult {
                    server_id: server.id.clone(),
                    status: "password-required".to_owned(),
                    detail: Some(
                        "Enter a password for this session or save one in the OS credential store."
                            .to_owned(),
                    ),
                    host_key: None,
                },
            });
        }
        let servers = persist_server(&app, &state, &server).await?;
        let start = if server.monitored {
            start_task(app, &state, server, None).await?
        } else {
            StartResult {
                server_id: server.id.clone(),
                status: "verified".to_owned(),
                detail: None,
                host_key: None,
            }
        };
        Ok(ApplyServerResult { servers, start })
    }
    .await;
    if result.is_err() && has_new_session_password {
        state.session_credentials.clear(&server_id).await;
    }
    result
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
        stop_task(&state, &server.id, true).await;
        state
            .statuses
            .lock()
            .await
            .insert(server.id.clone(), "stopped".to_owned());
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
    stop_task(&state, &server_id, true).await;
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
) -> Result<StartResult, String> {
    start_task(app, &state, server, interval_seconds).await
}

#[tauri::command]
async fn stop_monitoring(state: State<'_, AppState>, server_id: String) -> Result<(), String> {
    stop_task(&state, &server_id, true).await;
    state
        .statuses
        .lock()
        .await
        .insert(server_id, "stopped".to_owned());
    Ok(())
}

#[tauri::command]
async fn clear_session_credential(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<(), String> {
    state.session_credentials.clear(&server_id).await;
    Ok(())
}

#[tauri::command]
async fn recheck_monitoring(
    app: AppHandle,
    state: State<'_, AppState>,
    server: ServerConfig,
) -> Result<StartResult, String> {
    let server_id = server.id.clone();
    stop_task(&state, &server_id, false).await;
    state
        .statuses
        .lock()
        .await
        .insert(server_id.clone(), "rechecking".to_owned());
    state.errors.lock().await.remove(&server_id);
    let interval = *state.interval_seconds.lock().await;
    let result = match start_task(app, &state, server, Some(interval)).await {
        Ok(result) => result,
        Err(error) => {
            state
                .statuses
                .lock()
                .await
                .insert(server_id.clone(), "offline".to_owned());
            state.errors.lock().await.insert(server_id, error.clone());
            return Err(error);
        }
    };
    if result.status != "started" {
        state
            .statuses
            .lock()
            .await
            .insert(server_id, result.status.clone());
    }
    Ok(result)
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
    Ok(DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?
        .to_string_lossy()
        .into_owned())
}

#[tauri::command]
async fn query_history(day: String) -> Result<HistoryResponse, String> {
    let target_date = NaiveDate::parse_from_str(&day, "%Y-%m-%d")
        .map_err(|_| "history day must use YYYY-MM-DD".to_owned())?;
    let root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let store = JsonHistoryStore::new(root);

    let (candidate_days, utc_start, utc_end) = history_query_window(target_date)?;
    // Widen the raw-stamp prefilter window by 15h on each side: any real
    // timezone offset is within ±14h, so lines that could possibly pass the
    // exact per-entry filter are always parsed.
    let skip_before = (utc_start - chrono::Duration::hours(15))
        .format("%Y-%m-%dT%H:%M:%S")
        .to_string();
    let skip_after_excl = (utc_end + chrono::Duration::hours(15))
        .format("%Y-%m-%dT%H:%M:%S")
        .to_string();

    let mut all_entries = Vec::new();
    let mut total_corrupt = 0;
    // Dedup key: exact instant plus a structural hash of the record, instead
    // of a fully re-serialized record string. Holds O(1) memory per entry
    // rather than an owned copy of every line.
    let mut seen_keys: std::collections::HashSet<(i64, u64)> = std::collections::HashSet::new();

    for candidate in &candidate_days {
        let path = store.history_root.join(format!("{candidate}.v2.jsonl"));
        if path.exists() {
            if let Ok(file) = fs::File::open(&path) {
                let reader = std::io::BufReader::with_capacity(1 << 20, file);
                let read = serverpulse_core::read_history_jsonl_filtered(
                    reader,
                    &skip_before,
                    &skip_after_excl,
                );
                total_corrupt += read.corrupt_lines;
                all_entries.extend(read.entries);
            }
        }
        let legacy_path = store.history_root.join(format!("{candidate}.json"));
        if legacy_path.exists() {
            let text = fs::read_to_string(&legacy_path).unwrap_or_default();
            let legacy = serverpulse_core::read_history_json(&text);
            total_corrupt += legacy.corrupt_lines;
            for entry in legacy.entries {
                all_entries.push(entry);
            }
        }
    }

    // Frozen: attribution history is no longer served; the files stay on
    // disk untouched for a possible later re-enable or removal.
    let mut disk_attribution: Vec<serverpulse_core::DiskAttributionRecord> = Vec::new();
    if !serverpulse_core::DISK_ATTRIBUTION_FROZEN {
        for candidate in candidate_days.iter() {
            let path = store
                .history_root
                .join("attribution")
                .join(format!("{candidate}.jsonl"));
            if path.exists() {
                let text = fs::read_to_string(&path).unwrap_or_default();
                for line in text.lines() {
                    if let Ok(record) = serverpulse_core::parse_disk_attribution_line(line) {
                        disk_attribution.push(record);
                    }
                }
            }
        }
        disk_attribution.sort_by(|a, b| a.scanned_at.cmp(&b.scanned_at));
    }

    let mut filtered_entries = Vec::new();
    for mut entry in all_entries {
        let ts_str = entry
            .record
            .get("Timestamp")
            .and_then(|v| v.as_str())
            .unwrap_or_default();
        let (ts_millis, in_requested_local_day, local_iso_str) = if let Ok(parsed) =
            chrono::DateTime::parse_from_rfc3339(ts_str)
        {
            let utc_dt = parsed.with_timezone(&Utc);
            let local_dt = utc_dt.with_timezone(&chrono::Local);
            (
                utc_dt.timestamp_millis(),
                utc_dt >= utc_start && utc_dt < utc_end,
                local_dt.format("%Y-%m-%dT%H:%M:%S").to_string(),
            )
        } else if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(ts_str, "%Y-%m-%dT%H:%M:%S")
        {
            let local_dt = naive
                .and_local_timezone(chrono::Local)
                .earliest()
                .unwrap_or_else(|| naive.and_utc().with_timezone(&chrono::Local));
            let utc_dt = local_dt.with_timezone(&Utc);
            (
                utc_dt.timestamp_millis(),
                local_dt.date_naive() == target_date,
                local_dt.format("%Y-%m-%dT%H:%M:%S").to_string(),
            )
        } else if let Ok(naive) = chrono::NaiveDateTime::parse_from_str(ts_str, "%Y/%m/%d %H:%M:%S")
        {
            let local_dt = naive
                .and_local_timezone(chrono::Local)
                .earliest()
                .unwrap_or_else(|| naive.and_utc().with_timezone(&chrono::Local));
            let utc_dt = local_dt.with_timezone(&Utc);
            (
                utc_dt.timestamp_millis(),
                local_dt.date_naive() == target_date,
                local_dt.format("%Y-%m-%dT%H:%M:%S").to_string(),
            )
        } else {
            continue;
        };

        if in_requested_local_day {
            if let Some(obj) = entry.record.as_object_mut() {
                obj.insert(
                    "Timestamp".to_owned(),
                    serde_json::Value::String(local_iso_str),
                );
            }
            let key_hash = {
                use std::hash::{Hash, Hasher};
                let mut hasher = std::collections::hash_map::DefaultHasher::new();
                entry.record.hash(&mut hasher);
                hasher.finish()
            };
            if seen_keys.insert((ts_millis, key_hash)) {
                filtered_entries.push((ts_millis, entry));
            }
        }
    }

    filtered_entries.sort_by_key(|(ts, _)| *ts);
    let entries = filtered_entries.into_iter().map(|(_, e)| e).collect();

    Ok(HistoryResponse {
        entries,
        corrupt_lines: total_corrupt,
        disk_attribution,
    })
}

/// Reads only the per-day disk attribution records for a local calendar day.
/// Used by the periodic auto-refresh in every window; unlike query_history it
/// never parses the metric history files, keeping the 5-minute poll cheap.
#[tauri::command]
async fn query_disk_attribution(day: String) -> Result<DiskAttributionResponse, String> {
    // Frozen: attribution is no longer served; existing files stay on disk.
    if serverpulse_core::DISK_ATTRIBUTION_FROZEN {
        return Ok(DiskAttributionResponse {
            disk_attribution: Vec::new(),
        });
    }
    let target_date = NaiveDate::parse_from_str(&day, "%Y-%m-%d")
        .map_err(|_| "history day must use YYYY-MM-DD".to_owned())?;
    let root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let store = JsonHistoryStore::new(root);
    let (candidate_days, _utc_start, _utc_end) = history_query_window(target_date)?;

    let mut disk_attribution = Vec::new();
    for candidate in candidate_days.iter() {
        let path = store
            .history_root
            .join("attribution")
            .join(format!("{candidate}.jsonl"));
        if path.exists() {
            let text = fs::read_to_string(&path).unwrap_or_default();
            for line in text.lines() {
                if let Ok(record) = serverpulse_core::parse_disk_attribution_line(line) {
                    disk_attribution.push(record);
                }
            }
        }
    }
    disk_attribution.sort_by(|a, b| a.scanned_at.cmp(&b.scanned_at));

    Ok(DiskAttributionResponse { disk_attribution })
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
    let password = zeroize::Zeroizing::new(password);
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
async fn preview_import(
    source: String,
    target: Option<String>,
) -> Result<serverpulse_platform::MigrationPreview, String> {
    let manager = DataRootManager::default();
    let target = target
        .map(std::path::PathBuf::from)
        .unwrap_or(manager.default_root.clone());
    manager
        .preview_import(std::path::Path::new(&source), &target)
        .map_err(to_command_error)
}

#[tauri::command]
async fn apply_import(
    source: String,
    target: Option<String>,
    mode: ConflictMode,
) -> Result<serverpulse_platform::MigrationResult, String> {
    let manager = DataRootManager::default();
    let target = target
        .map(std::path::PathBuf::from)
        .unwrap_or(manager.default_root.clone());
    manager
        .import(std::path::Path::new(&source), &target, mode)
        .map_err(to_command_error)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentMergeResult {
    pub server_id: String,
    pub status: String,
    pub pulled_lines: usize,
    pub added_minutes: usize,
    pub updated_servers: usize,
    pub skipped_servers: usize,
    pub corrupt_lines: usize,
    pub record_files: usize,
    pub attribution_lines: usize,
    pub cursor_utc: Option<String>,
    pub error: Option<String>,
}

async fn resolve_server_and_target(
    server_id: &str,
    state: &AppState,
) -> Result<(ServerConfig, SshTarget, std::path::PathBuf), String> {
    let data_root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let (_, servers) = writable_servers()?;
    let server = servers
        .into_iter()
        .find(|s| s.id == server_id)
        .ok_or_else(|| format!("Server not found: {}", server_id))?;
    let target = target_with_credentials(&server, state).await?;
    Ok((server, target, data_root))
}

#[tauri::command]
async fn get_agent_states(
) -> Result<HashMap<String, serverpulse_platform::AgentServerState>, String> {
    let data_root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let state_file = serverpulse_platform::read_agent_state(&data_root);
    Ok(state_file.servers)
}

#[tauri::command]
async fn check_agent_status(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (_server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let script = serverpulse_core::generate_agent_status_script();
    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });

    match ssh.execute_short_command(&target, script).await {
        Ok(output) => {
            let info = serverpulse_core::parse_agent_status_output(&output.stdout, 30);
            entry.last_status = info.status.as_str().to_string();
            entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
            entry.last_error = info.error.unwrap_or_default();
        }
        Err(e) => {
            entry.last_status = "unknown".to_string();
            entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
            entry.last_error = e.to_string();
        }
    }
    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[tauri::command]
async fn check_all_agent_statuses(
    state: State<'_, AppState>,
) -> Result<HashMap<String, serverpulse_platform::AgentServerState>, String> {
    let data_root = DataRootManager::default()
        .resolve()
        .map_err(to_command_error)?;
    let (_, servers) = writable_servers()?;
    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let ssh = SystemOpenSsh::default();
    let script = serverpulse_core::generate_agent_status_script();

    for server in servers {
        let target = target_with_credentials(&server, &state).await?;
        let entry = state_file
            .servers
            .entry(server.id.clone())
            .or_insert_with(|| serverpulse_platform::AgentServerState {
                id: server.id.clone(),
                ..Default::default()
            });

        match ssh.execute_short_command(&target, script).await {
            Ok(output) => {
                let info = serverpulse_core::parse_agent_status_output(&output.stdout, 30);
                entry.last_status = info.status.as_str().to_string();
                entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
                entry.last_error = info.error.unwrap_or_default();
            }
            Err(e) => {
                entry.last_status = "unknown".to_string();
                entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
                entry.last_error = e.to_string();
            }
        }
    }
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(state_file.servers)
}

#[tauri::command]
async fn deploy_and_start_agent(
    state: State<'_, AppState>,
    server_id: String,
    interval_seconds: u32,
    retention_days: u32,
    scan_enabled: bool,
    scan_hour: u32,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let agent_sh = serverpulse_core::generate_agent_script(
        &server.id,
        &server.label,
        &server.host,
        interval_seconds,
        retention_days,
        scan_enabled,
        scan_hour,
        SAMPLE_SCRIPT,
    );
    let config_text = serverpulse_core::generate_agent_config(
        &server.id,
        &server.label,
        &server.host,
        interval_seconds,
        retention_days,
        scan_enabled,
        scan_hour,
    );
    let inject_sh =
        serverpulse_core::generate_agent_inject_script(&agent_sh, &config_text, SCAN_SCRIPT);

    let output = ssh
        .execute_short_command(&target, &inject_sh)
        .await
        .map_err(|e| format!("SSH execution error: {}", e))?;

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });

    entry.interval_seconds = interval_seconds;
    entry.retention_days = retention_days;
    // Record the effective state: while attribution is frozen the remote
    // scan can never be enabled, no matter what was requested.
    entry.scan_enabled = scan_enabled && !serverpulse_core::DISK_ATTRIBUTION_FROZEN;
    entry.scan_hour = scan_hour;
    entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));

    if output.stdout.contains("SP_AGENT_RESULT=started")
        || output.stdout.contains("SP_AGENT_RESULT=already_running")
    {
        entry.last_status = "running".to_string();
        entry.last_error = String::new();
    } else if let Some(err_line) = output
        .stdout
        .lines()
        .find(|l| l.starts_with("SP_AGENT_ERROR="))
    {
        entry.last_status = "stopped".to_string();
        entry.last_error = err_line.replace("SP_AGENT_ERROR=", "");
    } else if !output.stderr.is_empty() {
        entry.last_status = "unknown".to_string();
        entry.last_error = output.stderr.clone();
    } else {
        entry.last_status = "running".to_string();
        entry.last_error = String::new();
    }

    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[tauri::command]
async fn stop_agent(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (_server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let stop_sh = serverpulse_core::generate_agent_stop_script();
    let _ = ssh.execute_short_command(&target, stop_sh).await;

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });
    entry.last_status = "stopped".to_string();
    entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
    entry.last_error = String::new();
    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[tauri::command]
async fn restart_agent(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let state_file = serverpulse_platform::read_agent_state(&data_root);
    let existing_entry = state_file.servers.get(&server_id);
    let interval = existing_entry.map(|e| e.interval_seconds).unwrap_or(5);
    let retention = existing_entry.map(|e| e.retention_days).unwrap_or(30);
    let scan_enabled = existing_entry.map(|e| e.scan_enabled).unwrap_or(false)
        && !serverpulse_core::DISK_ATTRIBUTION_FROZEN;
    let scan_hour = existing_entry.map(|e| e.scan_hour).unwrap_or(3);

    let ssh = SystemOpenSsh::default();
    let stop_sh = serverpulse_core::generate_agent_stop_script();
    let _ = ssh.execute_short_command(&target, stop_sh).await;

    let agent_sh = serverpulse_core::generate_agent_script(
        &server.id,
        &server.label,
        &server.host,
        interval,
        retention,
        scan_enabled,
        scan_hour,
        SAMPLE_SCRIPT,
    );
    let config_text = serverpulse_core::generate_agent_config(
        &server.id,
        &server.label,
        &server.host,
        interval,
        retention,
        scan_enabled,
        scan_hour,
    );
    let inject_sh =
        serverpulse_core::generate_agent_inject_script(&agent_sh, &config_text, SCAN_SCRIPT);
    let _ = ssh.execute_short_command(&target, &inject_sh).await;

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });
    entry.last_status = "running".to_string();
    entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
    entry.last_error = String::new();
    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[tauri::command]
async fn update_agent_config(
    state: State<'_, AppState>,
    server_id: String,
    interval_seconds: u32,
    retention_days: u32,
    scan_enabled: bool,
    scan_hour: u32,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let config_text = serverpulse_core::generate_agent_config(
        &server.id,
        &server.label,
        &server.host,
        interval_seconds,
        retention_days,
        scan_enabled,
        scan_hour,
    );
    let config_sh = serverpulse_core::generate_agent_config_script(&config_text);
    let ssh = SystemOpenSsh::default();
    let _ = ssh.execute_short_command(&target, &config_sh).await;

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });
    entry.interval_seconds = interval_seconds;
    entry.retention_days = retention_days;
    // Effective state: frozen attribution can never be enabled remotely.
    entry.scan_enabled = scan_enabled && !serverpulse_core::DISK_ATTRIBUTION_FROZEN;
    entry.scan_hour = scan_hour;
    entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[tauri::command]
async fn uninstall_agent(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_platform::AgentServerState, String> {
    let (_server, target, data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let uninstall_sh = serverpulse_core::generate_agent_uninstall_script();
    let _ = ssh.execute_short_command(&target, uninstall_sh).await;

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });
    entry.last_status = "not_installed".to_string();
    entry.last_status_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
    entry.last_error = String::new();
    let res = entry.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);
    Ok(res)
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DiskScanTriggerResult {
    server_id: String,
    status: String, // launched | already-running | failed
    detail: Option<String>,
}

#[tauri::command]
async fn trigger_disk_scan(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<DiskScanTriggerResult, String> {
    // Frozen: refuse to deploy or launch the scanner; no SSH work happens.
    if serverpulse_core::DISK_ATTRIBUTION_FROZEN {
        return Ok(DiskScanTriggerResult {
            server_id,
            status: "failed".to_owned(),
            detail: Some("per-user disk attribution scanning is frozen in this version".to_owned()),
        });
    }
    let (_server, target, _data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let script = serverpulse_core::generate_scan_deploy_and_trigger_script(SCAN_SCRIPT, &server_id);
    let output = ssh
        .execute_short_command(&target, &script)
        .await
        .map_err(to_command_error)?;
    if output.stdout.contains("SP_SCAN_RESULT=launched") {
        Ok(DiskScanTriggerResult {
            server_id,
            status: "launched".to_owned(),
            detail: None,
        })
    } else if output.stdout.contains("SP_SCAN_RESULT=already_running") {
        Ok(DiskScanTriggerResult {
            server_id,
            status: "already-running".to_owned(),
            detail: None,
        })
    } else {
        let detail = if output.stderr.is_empty() {
            "scan trigger did not report a launch".to_owned()
        } else {
            output.stderr.lines().take(2).collect::<Vec<_>>().join(" ")
        };
        Ok(DiskScanTriggerResult {
            server_id,
            status: "failed".to_owned(),
            detail: Some(detail),
        })
    }
}

#[tauri::command]
async fn get_disk_scan_status(
    state: State<'_, AppState>,
    server_id: String,
) -> Result<serverpulse_core::DiskScanStatusInfo, String> {
    // Frozen: report a stable inactive status without touching the server.
    if serverpulse_core::DISK_ATTRIBUTION_FROZEN {
        return Ok(serverpulse_core::DiskScanStatusInfo {
            installed: false,
            active: false,
            pid: None,
            state: "frozen".to_owned(),
            started_at: None,
            finished_at: None,
            last_mount: None,
            last_file: None,
        });
    }
    let (_server, target, _data_root) = resolve_server_and_target(&server_id, &state).await?;
    let ssh = SystemOpenSsh::default();
    let output = ssh
        .execute_short_command(&target, serverpulse_core::generate_scan_status_script())
        .await
        .map_err(to_command_error)?;
    Ok(serverpulse_core::parse_scan_status_output(&output.stdout))
}

async fn pull_and_merge_records_impl(
    state: &AppState,
    server_id: String,
    clean_remote: bool,
) -> Result<AgentMergeResult, String> {
    let (_server, target, data_root) = resolve_server_and_target(&server_id, state).await?;
    let (_, all_servers) = writable_servers()?;
    let known_ids: Vec<String> = all_servers.iter().map(|s| s.id.clone()).collect();

    let mut state_file = serverpulse_platform::read_agent_state(&data_root);
    let entry = state_file
        .servers
        .entry(server_id.clone())
        .or_insert_with(|| serverpulse_platform::AgentServerState {
            id: server_id.clone(),
            ..Default::default()
        });
    let cursor_utc = entry.merge_cursor_utc.clone();

    let ssh = SystemOpenSsh::default();
    let pull_sh = serverpulse_core::generate_agent_pull_script(cursor_utc.as_deref());
    let output = ssh
        .execute_short_command_with_timeout(&target, &pull_sh, AGENT_PULL_TIMEOUT)
        .await
        .map_err(|e| format!("SSH pull failed: {}", e))?;

    let pull_result = serverpulse_core::parse_agent_pull_output(
        &output.stdout,
        &known_ids,
        cursor_utc.as_deref(),
    );

    // History files are partitioned by UTC day; local dates are converted to
    // UTC only when queried for display.
    let mut day_groups: HashMap<String, Vec<serverpulse_core::AgentPulledEntry>> = HashMap::new();
    for item in pull_result.entries {
        day_groups
            .entry(item.utc_day.clone())
            .or_default()
            .push(item);
    }

    let history_dir = data_root.join("history");
    let _ = fs::create_dir_all(&history_dir);
    let mut total_added = 0;
    let mut total_updated = 0;
    let mut total_skipped = 0;

    for (day, day_entries) in day_groups {
        let day_path = history_dir.join(format!("{}.v2.jsonl", day));
        let existing_lines = if day_path.exists() {
            fs::read_to_string(&day_path)
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        } else {
            Vec::new()
        };

        let (merged_lines, stats) =
            serverpulse_core::merge_agent_day_entries(&existing_lines, &day_entries);
        total_added += stats.added_minutes;
        total_updated += stats.updated_servers;
        total_skipped += stats.skipped_servers;

        let content = merged_lines.join("\n") + if merged_lines.is_empty() { "" } else { "\n" };
        let _ = serverpulse_platform::atomic_write(&day_path, content.as_bytes());
    }

    // Frozen: attribution lines are not pulled or merged; existing local
    // records are preserved untouched.
    let mut attr_rows_total = 0usize;
    if !serverpulse_core::DISK_ATTRIBUTION_FROZEN {
        let (attr_rows, _attr_corrupt) =
            serverpulse_core::parse_agent_attribution_output(&output.stdout);
        attr_rows_total = attr_rows.len();
        let attribution_dir = history_dir.join("attribution");
        let _ = fs::create_dir_all(&attribution_dir);
        let mut attr_days: std::collections::BTreeMap<String, Vec<String>> = Default::default();
        for (day, line) in attr_rows {
            attr_days.entry(day).or_default().push(line);
        }
        for (day, lines) in &attr_days {
            // Defense in depth: never join a non-canonical day into a file path.
            if !serverpulse_core::is_valid_day_shape(day) {
                continue;
            }
            let path = attribution_dir.join(format!("{day}.jsonl"));
            let existing = fs::read_to_string(&path).unwrap_or_default();
            let incoming = lines.join("\n") + "\n";
            let (merged, conflicts) =
                serverpulse_core::merge_attribution_lines(&existing, &incoming);
            if conflicts > 0 {
                append_error_log(
                    &data_root,
                    &format!(
                        "disk attribution merge ({day}): {conflicts} conflicting duplicate(s) kept first-seen"
                    ),
                );
            }
            let _ = serverpulse_platform::atomic_write(&path, merged.as_bytes());
        }
    }

    // Remote clean if requested
    if clean_remote {
        if let Some(max_utc) = &pull_result.max_utc_minute {
            let clean_sh = serverpulse_core::generate_agent_clean_script(max_utc);
            let _ = ssh.execute_short_command(&target, &clean_sh).await;
        }
    }

    // Update state
    if let Some(max_utc) = &pull_result.max_utc_minute {
        entry.merge_cursor_utc = Some(max_utc.clone());
    }
    entry.last_merge_at = Some(Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true));
    entry.last_merge_summary = Some(format!(
        "Pulled {} lines, added {} minutes, updated {} records, {} attribution lines.",
        pull_result.pulled_lines, total_added, total_updated, attr_rows_total
    ));
    let new_cursor = entry.merge_cursor_utc.clone();
    let _ = serverpulse_platform::save_agent_state(&data_root, &state_file);

    Ok(AgentMergeResult {
        server_id,
        status: "ok".to_string(),
        pulled_lines: pull_result.pulled_lines,
        added_minutes: total_added,
        updated_servers: total_updated,
        skipped_servers: total_skipped,
        corrupt_lines: pull_result.corrupt_lines,
        record_files: pull_result.record_files,
        attribution_lines: attr_rows_total,
        cursor_utc: new_cursor,
        error: None,
    })
}

#[tauri::command]
async fn pull_and_merge_records(
    state: State<'_, AppState>,
    server_id: String,
    clean_remote: bool,
) -> Result<AgentMergeResult, String> {
    pull_and_merge_records_impl(&state, server_id, clean_remote).await
}

#[tauri::command]
async fn pull_and_merge_all_records(
    state: State<'_, AppState>,
    clean_remote: bool,
) -> Result<HashMap<String, AgentMergeResult>, String> {
    let (_, all_servers) = writable_servers()?;
    let mut results = HashMap::new();
    for server in all_servers {
        match pull_and_merge_records_impl(&state, server.id.clone(), clean_remote).await {
            Ok(res) => {
                results.insert(server.id, res);
            }
            Err(err) => {
                results.insert(
                    server.id.clone(),
                    AgentMergeResult {
                        server_id: server.id,
                        status: "error".to_string(),
                        pulled_lines: 0,
                        added_minutes: 0,
                        updated_servers: 0,
                        skipped_servers: 0,
                        corrupt_lines: 0,
                        record_files: 0,
                        attribution_lines: 0,
                        cursor_utc: None,
                        error: Some(err),
                    },
                );
            }
        }
    }
    Ok(results)
}

#[cfg(target_os = "windows")]
fn apply_window_dark_theme(window: &tauri::WebviewWindow) {
    use windows_sys::Win32::Foundation::HWND;
    use windows_sys::Win32::Graphics::Dwm::{DwmSetWindowAttribute, DWMWA_USE_IMMERSIVE_DARK_MODE};
    if let Ok(hwnd) = window.hwnd() {
        let hwnd = hwnd.0 as HWND;
        let dark: i32 = 1;
        unsafe {
            // Standard Windows 10 20H1+ and Windows 11 dark mode
            DwmSetWindowAttribute(
                hwnd,
                DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
                &dark as *const _ as *const _,
                std::mem::size_of::<i32>() as u32,
            );
            // Fallback attribute 19 for older Windows 10 (1809 - 1909)
            let old_dark_mode_attr: u32 = 19;
            DwmSetWindowAttribute(
                hwnd,
                old_dark_mode_attr,
                &dark as *const _ as *const _,
                std::mem::size_of::<i32>() as u32,
            );
            // Windows 11 build 22000+: set caption background to #111713 (COLORREF 0x00131711)
            let caption_color: u32 = 0x00131711;
            DwmSetWindowAttribute(
                hwnd,
                35, // DWMWA_CAPTION_COLOR
                &caption_color as *const _ as *const _,
                std::mem::size_of::<u32>() as u32,
            );
            // Title text color: #f2f7f4 (COLORREF 0x00F4F7F2)
            let text_color: u32 = 0x00F4F7F2;
            DwmSetWindowAttribute(
                hwnd,
                36, // DWMWA_TEXT_COLOR
                &text_color as *const _ as *const _,
                std::mem::size_of::<u32>() as u32,
            );
            // Window border outline color: #223226 (COLORREF 0x00263222)
            let border_color: u32 = 0x00263222;
            DwmSetWindowAttribute(
                hwnd,
                34, // DWMWA_BORDER_COLOR
                &border_color as *const _ as *const _,
                std::mem::size_of::<u32>() as u32,
            );
        }
    }
}

#[tauri::command]
async fn open_window(app: AppHandle, kind: String) -> Result<(), String> {
    let (label, title) = match kind.as_str() {
        "manage" => ("manage", "SSH Servers"),
        "history" => ("history", "Usage History"),
        _ => return Err("unknown window kind".to_owned()),
    };
    if let Some(window) = app.get_webview_window(label) {
        #[cfg(target_os = "windows")]
        apply_window_dark_theme(&window);
        let _ = window.set_always_on_top(true);
        window.show().map_err(to_command_error)?;
        window.set_focus().map_err(to_command_error)?;
        return Ok(());
    }
    let (width, height) = match kind.as_str() {
        "history" => (940.0, 700.0),
        _ => (760.0, 600.0),
    };
    let window = WebviewWindowBuilder::new(
        &app,
        label,
        WebviewUrl::App(format!("index.html?view={kind}").into()),
    )
    .title(title)
    .inner_size(width, height)
    .min_inner_size(500.0, 400.0)
    .theme(Some(tauri::Theme::Dark))
    .resizable(true)
    .always_on_top(true)
    .center()
    .build()
    .map_err(to_command_error)?;

    #[cfg(target_os = "windows")]
    apply_window_dark_theme(&window);

    Ok(())
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
    let window = app
        .get_webview_window("main")
        .ok_or("Main window not found")?;
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
        use windows_sys::Win32::Foundation::POINT;
        use windows_sys::Win32::UI::WindowsAndMessaging::GetCursorPos;
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
                    (
                        false,
                        POINT { x: 0, y: 0 },
                        RECT {
                            left: 0,
                            top: 0,
                            right: 0,
                            bottom: 0,
                        },
                        0,
                        0,
                        0,
                    )
                } else {
                    let mut cur = POINT { x: 0, y: 0 };
                    GetCursorPos(&mut cur);
                    let mut r = RECT {
                        left: 0,
                        top: 0,
                        right: 0,
                        bottom: 0,
                    };
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
    let window = app
        .get_webview_window("main")
        .ok_or("Main window not found")?;
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
    let window = app
        .get_webview_window("main")
        .ok_or("Main window not found")?;
    let steps = 15;
    let step_delay = Duration::from_millis((duration_ms / steps as u64).max(1));
    for i in 1..=steps {
        let progress = i as f64 / steps as f64;
        let ease = 1.0 - (1.0 - progress).powi(3);
        let curr_x = from_x + ((to_x - from_x) as f64 * ease).round() as i32;
        let curr_y = from_y + ((to_y - from_y) as f64 * ease).round() as i32;
        let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
            x: curr_x,
            y: curr_y,
        }));
        tokio::time::sleep(step_delay).await;
    }
    let _ = window.set_position(tauri::Position::Physical(tauri::PhysicalPosition {
        x: to_x,
        y: to_y,
    }));
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

    let icon_image =
        tauri::image::Image::from_bytes(include_bytes!("../../assets/server-pulse.ico"))
            .ok()
            .or_else(|| app.default_window_icon().cloned());

    let mut builder = TrayIconBuilder::new()
        .tooltip("Server Pulse")
        .menu(&menu)
        .show_menu_on_left_click(false);

    if let Some(icon) = icon_image {
        builder = builder.icon(icon);
    }

    builder
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
    if std::env::var_os("SERVERPULSE_SESSION_TOKEN").is_some() {
        if let Ok(Some(password)) = session_credentials::askpass_password() {
            println!("{password}");
        }
        return true;
    }
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
                #[cfg(target_os = "windows")]
                apply_window_dark_theme(&main_win);
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
            probe_host_key,
            accept_host_key,
            forget_host_key,
            verify_and_apply_server,
            save_server,
            delete_server,
            start_monitoring,
            stop_monitoring,
            clear_session_credential,
            recheck_monitoring,
            set_all_monitoring_intervals,
            get_monitoring_state,
            get_data_root,
            validate_data_root,
            set_data_root,
            save_credential,
            delete_credential,
            query_history,
            query_disk_attribution,
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
            toggle_edge_dock_autohide,
            get_agent_states,
            check_agent_status,
            check_all_agent_statuses,
            deploy_and_start_agent,
            stop_agent,
            restart_agent,
            update_agent_config,
            uninstall_agent,
            pull_and_merge_records,
            pull_and_merge_all_records,
            trigger_disk_scan,
            get_disk_scan_status
        ])
        .build(tauri::generate_context!())
        .expect("error while building Server Pulse")
        .run(|app: &tauri::AppHandle, event: tauri::RunEvent| {
            if matches!(event, tauri::RunEvent::Exit) {
                let state = app.state::<AppState>();
                let tasks = state.tasks.clone();
                let credentials = state.session_credentials.clone();
                tauri::async_runtime::block_on(async move {
                    let mut active = tasks.lock().await;
                    for (_, task) in active.drain() {
                        let MonitoringTask { join, cancel } = task;
                        let _ = cancel.send(());
                        await_monitoring_task(join).await;
                    }
                    credentials.clear_all().await;
                });
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_history_records_use_utc_z_and_utc_file_day() {
        let instant = chrono::DateTime::parse_from_rfc3339("2026-08-20T23:59:59+08:00")
            .expect("timestamp")
            .with_timezone(&Utc);
        let (timestamp, day) = utc_history_bucket(instant);
        assert_eq!(timestamp, "2026-08-20T15:59:59Z");
        assert_eq!(day, "2026-08-20");
    }

    #[test]
    fn local_date_query_is_converted_to_utc_midnight_bounds() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).expect("date");
        let (start, end) = local_day_utc_range(date).expect("range");
        assert_eq!(start.with_timezone(&chrono::Local).date_naive(), date);
        assert_eq!(
            end.with_timezone(&chrono::Local).date_naive(),
            date.succ_opt().expect("next date")
        );
        assert!(end > start);
        assert!(end - start <= chrono::Duration::hours(26));
    }

    #[test]
    fn history_minute_throttle_records_once_per_utc_minute() {
        let mut slot: Option<String> = None;
        assert!(should_record_history_minute(
            &mut slot,
            "2026-08-23T05:14:01Z"
        ));
        // Same minute (any second) is suppressed regardless of the live
        // sampling interval.
        assert!(!should_record_history_minute(
            &mut slot,
            "2026-08-23T05:14:59Z"
        ));
        // Next minute records again.
        assert!(should_record_history_minute(
            &mut slot,
            "2026-08-23T05:15:00Z"
        ));
        // Day rollover changes the key and records.
        assert!(should_record_history_minute(
            &mut slot,
            "2026-08-24T00:00:30Z"
        ));
    }

    #[test]
    fn history_minute_throttle_handles_short_timestamps() {
        let mut slot: Option<String> = None;
        assert!(should_record_history_minute(&mut slot, "short"));
        assert!(!should_record_history_minute(&mut slot, "short"));
    }

    #[test]
    fn history_query_window_spreads_candidate_days_and_matches_range() {
        let date = NaiveDate::from_ymd_opt(2026, 8, 20).expect("date");
        let (days, start, end) = history_query_window(date).expect("window");
        // 契约：候选日覆盖 UTC 窗口两侧各多垫一天（±1 日），且升序无重复。
        let expected_first = start
            .date_naive()
            .pred_opt()
            .expect("previous day")
            .format("%Y-%m-%d")
            .to_string();
        let expected_last = end
            .date_naive()
            .succ_opt()
            .expect("next day")
            .format("%Y-%m-%d")
            .to_string();
        assert_eq!(days.first(), Some(&expected_first));
        assert_eq!(days.last(), Some(&expected_last));
        assert!(start < end);
        assert!(days.windows(2).all(|w| w[0] < w[1]));
    }
}
