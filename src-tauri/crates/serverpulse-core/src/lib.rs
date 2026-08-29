use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::time::Duration;
use thiserror::Error;

pub mod agent;
pub use agent::*;

pub const PROTOCOL_VERSION: u32 = 2;

/// Per-user disk attribution is frozen: the find-based scanner is never
/// deployed or scheduled, manual triggers refuse to run, and attribution
/// records are no longer pulled, merged, or served (existing records on
/// disk are preserved, only new writes stop). All code paths stay intact
/// behind this flag so the feature can be re-enabled — or fully removed
/// when it is decommissioned — without re-implementing them.
///
/// Must be flipped together with the frontend `DISK_ATTRIBUTION_FROZEN`.
/// Real-time disk capacity (df-based DISK row, per-mount lists and history
/// curves) is NOT part of this freeze.
pub const DISK_ATTRIBUTION_FROZEN: bool = true;

#[derive(Debug, Error)]
pub enum ServerPulseError {
    #[error("invalid metric output: {0}")]
    InvalidMetricOutput(String),
    #[error("invalid history data: {0}")]
    InvalidHistory(String),
    #[error("invalid server configuration: {0}")]
    InvalidConfig(String),
    #[error("authentication failed: {0}")]
    Authentication(String),
    #[error("operation timed out: {0}")]
    Timeout(String),
    #[error("unsupported operation: {0}")]
    Unsupported(String),
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
}

impl ServerPulseError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::InvalidMetricOutput(_) => "invalid_metric_output",
            Self::InvalidHistory(_) => "invalid_history",
            Self::InvalidConfig(_) => "invalid_config",
            Self::Authentication(_) => "authentication_failed",
            Self::Timeout(_) => "timeout",
            Self::Unsupported(_) => "unsupported",
            Self::Io(_) => "io_error",
            Self::Json(_) => "json_error",
        }
    }

    pub fn message_key(&self) -> &'static str {
        match self {
            Self::InvalidMetricOutput(_) => "error.metricOutput",
            Self::InvalidHistory(_) => "error.history",
            Self::InvalidConfig(_) => "error.serverConfig",
            Self::Authentication(_) => "error.authentication",
            Self::Timeout(_) => "error.timeout",
            Self::Unsupported(_) => "error.unsupported",
            Self::Io(_) => "error.io",
            Self::Json(_) => "error.json",
        }
    }

    pub fn retryable(&self) -> bool {
        matches!(self, Self::Io(_) | Self::Timeout(_))
    }

    pub fn public_error(&self) -> AppError {
        AppError {
            code: self.code().to_owned(),
            message_key: self.message_key().to_owned(),
            retryable: self.retryable(),
            detail: Some(sanitize_detail(&self.to_string())),
        }
    }
}

fn sanitize_detail(detail: &str) -> String {
    let mut sanitized = detail.to_owned();
    for key in ["password=", "passphrase=", "secret="] {
        loop {
            let Some(start) = sanitized.to_ascii_lowercase().find(key) else {
                break;
            };
            let value_start = start + key.len();
            let value_end = sanitized[value_start..]
                .find(char::is_whitespace)
                .map(|offset| value_start + offset)
                .unwrap_or(sanitized.len());
            sanitized.replace_range(value_start..value_end, "[REDACTED]");
            break;
        }
    }
    sanitized.lines().take(4).collect::<Vec<_>>().join(" ")
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AppError {
    pub code: String,
    pub message_key: String,
    pub retryable: bool,
    pub detail: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ServerConfig {
    pub id: String,
    pub label: String,
    pub host: String,
    #[serde(default)]
    pub user: Option<String>,
    #[serde(default)]
    pub port: Option<u16>,
    #[serde(default = "default_monitored")]
    pub monitored: bool,
    #[serde(default = "default_passwordless")]
    pub passwordless: bool,
}

fn default_monitored() -> bool {
    true
}

fn default_passwordless() -> bool {
    true
}

impl ServerConfig {
    pub fn validate(&self) -> Result<(), ServerPulseError> {
        if self.id.trim().is_empty() || self.label.trim().is_empty() {
            return Err(ServerPulseError::InvalidConfig(
                "id and label must not be empty".to_owned(),
            ));
        }
        if self.host.trim().is_empty()
            || !self
                .host
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        {
            return Err(ServerPulseError::InvalidConfig(
                "host must be a safe SSH alias".to_owned(),
            ));
        }
        if matches!(self.port, Some(0)) {
            return Err(ServerPulseError::InvalidConfig(
                "port must be between 1 and 65535".to_owned(),
            ));
        }
        Ok(())
    }
}

pub fn parse_server_configs(text: &str) -> Result<Vec<ServerConfig>, ServerPulseError> {
    let clean = text.trim_start_matches('\u{feff}').trim();
    if clean.is_empty() {
        return Ok(Vec::new());
    }
    let value: serde_json::Value = serde_json::from_str(clean)?;
    let items = value
        .get("servers")
        .or_else(|| value.get("Servers"))
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut servers = Vec::with_capacity(items.len());
    for item in items {
        let server = if let Ok(server) = serde_json::from_value::<ServerConfig>(item.clone()) {
            server
        } else {
            let id = string_field(&item, &["id", "Id"])
                .or_else(|| string_field(&item, &["sshTarget", "SshTarget"]))
                .ok_or_else(|| ServerPulseError::InvalidConfig("server id is missing".to_owned()))?;
            let host = string_field(&item, &["host", "Host"])
                .or_else(|| string_field(&item, &["sshTarget", "SshTarget"]))
                .or_else(|| string_field(&item, &["hostname", "HostName"]))
                .ok_or_else(|| ServerPulseError::InvalidConfig("server host is missing".to_owned()))?;
            ServerConfig {
                label: string_field(&item, &["label", "Label"]).unwrap_or_else(|| id.clone()),
                id,
                host,
                user: string_field(&item, &["user", "User"]),
                port: number_field(&item, &["port", "Port"]).and_then(|value| u16::try_from(value).ok()),
                monitored: bool_field(&item, &["monitored", "Monitored"]).unwrap_or(true),
                passwordless: bool_field(&item, &["passwordless", "Passwordless"]).unwrap_or(true),
            }
        };
        server.validate()?;
        servers.push(server);
    }
    Ok(servers)
}

fn string_field(value: &serde_json::Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| value.get(*key).and_then(serde_json::Value::as_str))
        .map(str::to_owned)
        .filter(|value| !value.trim().is_empty())
}

fn number_field(value: &serde_json::Value, keys: &[&str]) -> Option<u64> {
    keys.iter().find_map(|key| {
        value.get(*key).and_then(|value| {
            value
                .as_u64()
                .or_else(|| value.as_str().and_then(|value| value.parse().ok()))
        })
    })
}

fn bool_field(value: &serde_json::Value, keys: &[&str]) -> Option<bool> {
    keys.iter().find_map(|key| value.get(*key).and_then(serde_json::Value::as_bool))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum UserUsageStatus {
    Ok,
    Partial,
    Unavailable,
}

impl Default for UserUsageStatus {
    fn default() -> Self {
        Self::Unavailable
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CpuUserUsage {
    pub uid: String,
    pub name: String,
    pub percent: f64,
    #[serde(default)]
    pub process_count: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryUserUsage {
    pub uid: String,
    pub name: String,
    pub used_mib: f64,
    pub percent: Option<f64>,
    #[serde(default)]
    pub process_count: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GpuUserUsage {
    pub uid: String,
    pub name: String,
    pub used_mib: f64,
    pub percent: Option<f64>,
    #[serde(default)]
    pub process_count: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GpuMetric {
    pub index: u32,
    pub name: String,
    pub uuid: Option<String>,
    pub utilization: Option<f64>,
    pub memory_used_mib: Option<f64>,
    pub memory_total_mib: Option<f64>,
    pub temperature_c: Option<f64>,
    pub power_draw_w: Option<f64>,
    pub power_limit_w: Option<f64>,
    pub fan_percent: Option<f64>,
    pub user_memory_status: UserUsageStatus,
    pub user_memory: Vec<GpuUserUsage>,
    pub unmapped_processes: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskMetric {
    pub device: String,
    pub mount: String,
    pub total_mib: Option<f64>,
    pub used_mib: Option<f64>,
    pub percent: Option<f64>,
    pub fs_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MetricSnapshot {
    pub hostname: String,
    pub protocol_version: u32,
    pub cpu_percent: Option<f64>,
    pub memory_total_mib: Option<f64>,
    pub memory_used_mib: Option<f64>,
    pub memory_percent: Option<f64>,
    pub load_one: Option<f64>,
    pub load_five: Option<f64>,
    pub load_fifteen: Option<f64>,
    pub uptime_seconds: Option<f64>,
    pub cpu_user_status: UserUsageStatus,
    pub cpu_users: Vec<CpuUserUsage>,
    pub memory_user_status: UserUsageStatus,
    pub memory_users: Vec<MemoryUserUsage>,
    pub gpus: Vec<GpuMetric>,
    pub disks: Vec<DiskMetric>,
}

fn parse_number(value: Option<&String>) -> Option<f64> {
    value.and_then(|raw| raw.trim().parse::<f64>().ok())
}

fn parse_status(value: Option<&String>) -> UserUsageStatus {
    match value.map(String::as_str) {
        Some("ok") => UserUsageStatus::Ok,
        Some("partial") => UserUsageStatus::Partial,
        _ => UserUsageStatus::Unavailable,
    }
}

fn split_csv_line(line: &str) -> Vec<String> {
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '"' if quoted && chars.peek() == Some(&'"') => {
                current.push('"');
                chars.next();
            }
            '"' => quoted = !quoted,
            ',' if !quoted => {
                fields.push(current.trim().to_owned());
                current.clear();
            }
            _ => current.push(ch),
        }
    }
    fields.push(current.trim().to_owned());
    fields
}

fn parse_user_line(line: &str) -> Option<(String, String, String, Option<u32>)> {
    let mut fields = line.splitn(4, '\t');
    let uid = fields.next()?.to_owned();
    let name = fields.next()?.to_owned();
    let raw = fields.next()?.to_owned();
    let process_count = fields.next().and_then(|v| v.trim().parse::<u32>().ok());
    Some((uid, name, raw, process_count))
}

pub fn parse_metric_output(output: &str) -> Result<MetricSnapshot, ServerPulseError> {
    let mut values = HashMap::<String, String>::new();
    let mut gpu_lines = Vec::new();
    let mut cpu_users = Vec::new();
    let mut memory_users = Vec::new();
    let mut gpu_users = HashMap::<String, Vec<GpuUserUsage>>::new();
    let mut gpu_unmapped = HashMap::<String, u32>::new();
    let mut disks = Vec::new();
    let mut in_gpu_section = false;
    let mut in_disks_section = false;

    for raw_line in output.lines() {
        let line = raw_line.trim();
        if line == "GPUS_BEGIN" {
            in_gpu_section = true;
            continue;
        }
        if line == "GPUS_END" {
            in_gpu_section = false;
            continue;
        }
        if in_gpu_section {
            if !line.is_empty() {
                gpu_lines.push(line.to_owned());
            }
            continue;
        }
        if line == "DISKS_END" {
            in_disks_section = false;
            continue;
        }
        if line == "DISKS_BEGIN" {
            in_disks_section = true;
            continue;
        }
        if in_disks_section {
            if !line.is_empty() {
                let fields: Vec<&str> = line.split('\t').collect();
                if fields.len() >= 5 {
                    let total_mib = fields[2].trim().parse::<f64>().ok().map(|value| value / 1024.0);
                    let used_mib = fields[3].trim().parse::<f64>().ok().map(|value| value / 1024.0);
                    let percent = match (used_mib, total_mib) {
                        (Some(used), Some(total)) if total > 0.0 => {
                            Some((used * 100.0 / total).clamp(0.0, 100.0))
                        }
                        _ => None,
                    };
                    disks.push(DiskMetric {
                        device: fields[0].trim().to_owned(),
                        mount: fields[1].trim().to_owned(),
                        total_mib,
                        used_mib,
                        percent,
                        fs_type: fields[4].trim().to_owned(),
                    });
                }
            }
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key {
            "CPU_USER" => {
                if let Some((uid, name, raw, process_count)) = parse_user_line(value) {
                    if let Ok(percent) = raw.parse::<f64>() {
                        cpu_users.push(CpuUserUsage {
                            uid,
                            name,
                            percent: percent.clamp(0.0, 100.0),
                            process_count,
                        });
                    }
                }
            }
            "MEMORY_USER" => {
                if let Some((uid, name, raw, process_count)) = parse_user_line(value) {
                    if let Ok(used_mib) = raw.parse::<f64>() {
                        memory_users.push(MemoryUserUsage {
                            uid,
                            name,
                            used_mib: used_mib.max(0.0),
                            percent: None,
                            process_count,
                        });
                    }
                }
            }
            "GPU_USER" => {
                let mut fields = value.splitn(5, '\t');
                if let (Some(uuid), Some(uid), Some(name), Some(raw)) =
                    (fields.next(), fields.next(), fields.next(), fields.next())
                {
                    let process_count = fields.next().and_then(|v| v.trim().parse::<u32>().ok());
                    if let Ok(used_mib) = raw.parse::<f64>() {
                        gpu_users.entry(uuid.to_owned()).or_default().push(GpuUserUsage {
                            uid: uid.to_owned(),
                            name: name.to_owned(),
                            used_mib: used_mib.max(0.0),
                            percent: None,
                            process_count,
                        });
                    }
                }
            }
            "GPU_UNMAPPED" => {
                let mut fields = value.splitn(2, '\t');
                if let (Some(uuid), Some(raw)) = (fields.next(), fields.next()) {
                    if let Ok(count) = raw.parse::<u32>() {
                        gpu_unmapped.insert(uuid.to_owned(), count);
                    }
                }
            }
            _ => {
                values.insert(key.to_owned(), value.to_owned());
            }
        }
    }

    let hostname = values
        .get("HOSTNAME")
        .filter(|value| !value.is_empty())
        .cloned()
        .ok_or_else(|| ServerPulseError::InvalidMetricOutput("HOSTNAME is missing".to_owned()))?;
    let cpu_percent = parse_number(values.get("CPU_PERCENT"));
    if cpu_percent.is_none() {
        return Err(ServerPulseError::InvalidMetricOutput(
            "CPU_PERCENT is missing".to_owned(),
        ));
    }
    let memory_total_mib = parse_number(values.get("MEM_TOTAL_KIB")).map(|value| value / 1024.0);
    let memory_used_mib = parse_number(values.get("MEM_USED_KIB")).map(|value| value / 1024.0);
    let memory_percent = parse_number(values.get("MEM_PERCENT"));

    for user in &mut memory_users {
        user.percent = memory_total_mib
            .filter(|total| *total > 0.0)
            .map(|total| user.used_mib * 100.0 / total);
    }

    let gpus = gpu_lines
        .into_iter()
        .filter_map(|line| {
            let fields = split_csv_line(&line);
            if fields.len() < 10 {
                return None;
            }
            let uuid = (!fields[2].is_empty()).then(|| fields[2].clone());
            let mut users = uuid
                .as_ref()
                .and_then(|key| gpu_users.remove(key))
                .unwrap_or_default();
            let memory_total = fields[5].parse::<f64>().ok();
            for user in &mut users {
                user.percent = memory_total
                    .filter(|total| *total > 0.0)
                    .map(|total| user.used_mib * 100.0 / total);
            }
            Some(GpuMetric {
                index: fields[0].parse().ok()?,
                name: if fields[1].is_empty() {
                    "NVIDIA GPU".to_owned()
                } else {
                    fields[1].clone()
                },
                uuid: uuid.clone(),
                utilization: fields[3].parse().ok(),
                memory_used_mib: fields[4].parse().ok(),
                memory_total_mib: memory_total,
                temperature_c: fields[6].parse().ok(),
                power_draw_w: fields[7].parse().ok(),
                power_limit_w: fields[8].parse().ok(),
                fan_percent: fields[9].parse().ok(),
                user_memory_status: parse_status(values.get("GPU_USER_STATUS")),
                user_memory: users,
                unmapped_processes: uuid
                    .and_then(|key| gpu_unmapped.remove(&key))
                    .unwrap_or(0),
            })
        })
        .collect();

    Ok(MetricSnapshot {
        hostname,
        protocol_version: parse_number(values.get("PROTOCOL_VERSION")).unwrap_or(1.0) as u32,
        cpu_percent,
        memory_total_mib,
        memory_used_mib,
        memory_percent,
        load_one: parse_number(values.get("LOAD_1")),
        load_five: parse_number(values.get("LOAD_5")),
        load_fifteen: parse_number(values.get("LOAD_15")),
        uptime_seconds: parse_number(values.get("UPTIME_SECONDS")),
        cpu_user_status: parse_status(values.get("CPU_USER_STATUS")),
        cpu_users,
        memory_user_status: parse_status(values.get("MEMORY_USER_STATUS")),
        memory_users,
        gpus,
        disks,
    })
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskUserUsage {
    pub uid: String,
    pub name: String,
    pub used_mib: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiskAttributionRecord {
    pub kind: String,
    #[serde(default)]
    pub server_id: String,
    pub scanned_at: DateTime<Utc>,
    pub mount: String,
    #[serde(default)]
    pub device: Option<String>,
    #[serde(default)]
    pub fs_type: Option<String>,
    #[serde(default)]
    pub total_mib: Option<f64>,
    #[serde(default)]
    pub used_mib: Option<f64>,
    #[serde(default)]
    pub percent: Option<f64>,
    pub status: UserUsageStatus,
    #[serde(default)]
    pub duration_seconds: Option<u64>,
    #[serde(default)]
    pub skipped_entries: u64,
    #[serde(default)]
    pub users: Vec<DiskUserUsage>,
}

pub fn parse_disk_attribution_line(line: &str) -> Result<DiskAttributionRecord, ServerPulseError> {
    let clean = line.trim();
    if clean.is_empty() {
        return Err(ServerPulseError::InvalidHistory("empty attribution line".to_owned()));
    }
    let record: DiskAttributionRecord = serde_json::from_str(clean)
        .map_err(|error| ServerPulseError::InvalidHistory(format!("bad attribution line: {error}")))?;
    if record.kind != "diskAttribution" {
        return Err(ServerPulseError::InvalidHistory("line is not a diskAttribution record".to_owned()));
    }
    Ok(record)
}

/// Merge attribution lines, first-seen wins on key conflicts. Returns the
/// merged file content and the number of conflicting duplicates (same
/// `(serverId, mount, scannedAt)` key but a different payload) so callers can
/// surface the data loss instead of dropping it silently.
pub fn merge_attribution_lines(existing: &str, incoming: &str) -> (String, usize) {
    let mut seen = HashSet::new();
    let mut rows = Vec::new();
    let mut conflicts = 0usize;
    for line in existing.lines().chain(incoming.lines()) {
        let Ok(record) = parse_disk_attribution_line(line) else {
            continue;
        };
        let key = (
            record.server_id.clone(),
            record.mount.clone(),
            record.scanned_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        );
        if !seen.insert(key) {
            // Same key as an already-kept record: only count it as conflicting
            // when the payload actually differs from the first-seen row.
            if !rows.iter().any(|kept: &DiskAttributionRecord| kept == &record) {
                conflicts += 1;
            }
            continue;
        }
        rows.push(record);
    }
    rows.sort_by(|a, b| a.scanned_at.cmp(&b.scanned_at).then(a.mount.cmp(&b.mount)));
    let mut out = String::new();
    for record in rows {
        if let Ok(line) = serde_json::to_string(&record) {
            out.push_str(&line);
            out.push('\n');
        }
    }
    (out, conflicts)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HistoryEntry {
    #[serde(rename = "Version")]
    pub version: u32,
    #[serde(rename = "Record")]
    pub record: serde_json::Value,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct HistoryRead {
    pub entries: Vec<HistoryEntry>,
    pub corrupt_lines: usize,
}

pub fn read_history_jsonl(text: &str) -> HistoryRead {
    let mut result = HistoryRead::default();
    for line in text.lines().filter(|line| !line.trim().is_empty()) {
        let clean = line.trim_start_matches('\u{feff}').trim();
        match serde_json::from_str::<HistoryEntry>(clean) {
            Ok(entry) => result.entries.push(entry),
            Err(_) => result.corrupt_lines += 1,
        }
    }
    result
}

/// Streams a v2 history JSONL source and parses only the lines whose raw
/// `"Timestamp"` stamp falls inside `[window_start, window_end)`, compared
/// lexically as naive `YYYY-MM-DDTHH:MM:SS` prefixes. Out-of-window lines
/// never build a serde_json value tree, keeping peak memory proportional to
/// the in-range data instead of the whole file. Callers must widen the exact
/// UTC query window by at least one day on each side so that timestamps with
/// any timezone offset (and local-naive legacy stamps) can never be dropped
/// by the prefilter. Lines without a recognizable ISO-UTC stamp shape are
/// always parsed and left to the caller's exact filtering. Skipped lines are
/// neither parsed nor counted as corrupt.
pub fn read_history_jsonl_filtered(
    reader: impl std::io::BufRead,
    window_start: &str,
    window_end: &str,
) -> HistoryRead {
    const TIMESTAMP_NEEDLE: &str = "\"Timestamp\":\"";
    let mut result = HistoryRead::default();
    for line in reader.lines() {
        let Ok(line) = line else { break };
        let clean = line.trim_start_matches('\u{feff}').trim();
        let mut skip = false;
        if let Some(pos) = clean.find(TIMESTAMP_NEEDLE) {
            let rest = &clean[pos + TIMESTAMP_NEEDLE.len()..];
            if rest.len() > 19 && is_naive_stamp_shape(&rest[..19]) {
                // Only cheap-reject plain UTC stamps ("...Z"/"...msZ"). A
                // trailing offset ("+08:00") makes the naive prefix lie about
                // the instant, so such lines always go through full parsing.
                let suffix = rest.as_bytes()[19];
                if matches!(suffix, b'Z' | b'z' | b'.')
                    && (&rest[..19] < window_start || &rest[..19] >= window_end)
                {
                    skip = true;
                }
            }
        }
        if skip {
            continue;
        }
        match serde_json::from_str::<HistoryEntry>(clean) {
            Ok(entry) => result.entries.push(entry),
            Err(_) => result.corrupt_lines += 1,
        }
    }
    result
}

fn is_naive_stamp_shape(prefix: &str) -> bool {
    let bytes = prefix.as_bytes();
    bytes.len() == 19
        && bytes.iter().enumerate().all(|(i, b)| match i {
            4 | 7 => *b == b'-',
            10 => *b == b'T',
            13 | 16 => *b == b':',
            _ => b.is_ascii_digit(),
        })
}

pub fn read_history_json(text: &str) -> HistoryRead {
    let mut result = HistoryRead::default();
    let clean = text.trim_start_matches('\u{feff}').trim();
    let Ok(value) = serde_json::from_str::<serde_json::Value>(clean) else {
        result.corrupt_lines = 1;
        return result;
    };
    let records = value
        .get("Records")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .or_else(|| value.as_array().cloned())
        .unwrap_or_default();
    if records.is_empty() {
        result.corrupt_lines = 1;
        return result;
    }
    for record in records {
        if record.is_object() {
            result.entries.push(HistoryEntry { version: 1, record });
        } else {
            result.corrupt_lines += 1;
        }
    }
    result
}

pub fn merge_jsonl_lines(existing: &str, incoming: &str) -> String {
    let mut seen = HashSet::<String>::new();
    let mut output = Vec::<String>::new();
    for line in existing.lines().chain(incoming.lines()) {
        let normalized = line.trim();
        if normalized.is_empty() || !seen.insert(normalized.to_owned()) {
            continue;
        }
        output.push(normalized.to_owned());
    }
    if output.is_empty() {
        String::new()
    } else {
        format!("{}\n", output.join("\n"))
    }
}

pub fn history_day(timestamp: DateTime<Utc>) -> String {
    timestamp.format("%Y-%m-%d").to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RetryState {
    pub failures: u32,
    pub circuit_open: bool,
    pub next_retry_at: Option<DateTime<Utc>>,
}

impl Default for RetryState {
    fn default() -> Self {
        Self {
            failures: 0,
            circuit_open: false,
            next_retry_at: None,
        }
    }
}

impl RetryState {
    pub fn register_failure(&mut self, now: DateTime<Utc>) -> Duration {
        self.failures = self.failures.saturating_add(1);
        let seconds = [5, 15, 30, 60, 300][self.failures.saturating_sub(1).min(4) as usize];
        self.circuit_open = self.failures >= 5;
        self.next_retry_at = Some(now + chrono::Duration::seconds(seconds));
        Duration::from_secs(seconds as u64)
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    pub fn can_retry(&self, now: DateTime<Utc>) -> bool {
        self.next_retry_at.map(|deadline| now >= deadline).unwrap_or(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"PROTOCOL_VERSION=2
HOSTNAME=demo
CPU_PERCENT=42.5
MEM_TOTAL_KIB=2048000
MEM_USED_KIB=1024000
MEM_PERCENT=50.0
LOAD_1=1.0
LOAD_5=0.5
LOAD_15=0.25
UPTIME_SECONDS=120
CPU_USER=1000	alice	20	3
CPU_USER_STATUS=partial
MEMORY_USER=1000	alice	512
MEMORY_USER_STATUS=ok
GPUS_BEGIN
0,NVIDIA RTX 3090,uuid-0,80,4000,24000,55,100,350,50
GPUS_END
GPU_USER=uuid-0	1000	alice	4000	2
GPU_USER_STATUS=ok"#;

    #[test]
    fn parses_disks_section_and_computes_percent() {
        let mut output = String::from(SAMPLE);
        output.push_str("\nDISKS_BEGIN\n");
        output.push_str("/dev/sda1\t/\t419430400\t210034688\text4\n");
        output.push_str("not-a-disk-line\n");
        output.push_str("/dev/sdb1\t/data\t2048000\t1024000\txfs\n");
        output.push_str("DISKS_END\n");
        let snapshot = parse_metric_output(&output).expect("sample should parse");
        assert_eq!(snapshot.disks.len(), 2);
        let root = &snapshot.disks[0];
        assert_eq!(root.device, "/dev/sda1");
        assert_eq!(root.mount, "/");
        assert_eq!(root.fs_type, "ext4");
        let expected = (210034688.0 / 1024.0) * 100.0 / (419430400.0 / 1024.0);
        assert!((root.percent.unwrap() - expected).abs() < 0.001);
        assert!((root.total_mib.unwrap() - 409600.0).abs() < 0.001);
    }

    #[test]
    fn missing_disks_section_yields_empty_vec() {
        let snapshot = parse_metric_output(SAMPLE).expect("sample should parse");
        assert!(snapshot.disks.is_empty());
    }

    #[test]
    fn parses_protocol_v2_and_user_usage() {
        let snapshot = parse_metric_output(SAMPLE).expect("sample should parse");
        assert_eq!(snapshot.hostname, "demo");
        assert_eq!(snapshot.protocol_version, 2);
        assert_eq!(snapshot.cpu_users[0].name, "alice");
        assert_eq!(snapshot.cpu_users[0].process_count, Some(3));
        assert_eq!(snapshot.memory_users[0].percent, Some(25.6));
        assert_eq!(snapshot.memory_users[0].process_count, None);
        assert_eq!(snapshot.gpus[0].name, "NVIDIA RTX 3090");
        assert_eq!(snapshot.gpus[0].user_memory[0].process_count, Some(2));
    }

    #[test]
    fn rejects_incomplete_output() {
        let error = parse_metric_output("CPU_PERCENT=1").expect_err("must reject");
        assert_eq!(error.code(), "invalid_metric_output");
    }

    #[test]
    fn reads_corrupt_jsonl_without_losing_valid_lines() {
        let value = read_history_jsonl("{\"Version\":2,\"Record\":{}}\nnot-json\n");
        assert_eq!(value.entries.len(), 1);
        assert_eq!(value.corrupt_lines, 1);
    }

    #[test]
    fn reads_legacy_records_container() {
        let value = read_history_json(r#"{"Records":[{"Timestamp":"2026-08-15T10:00:00"}]}"#);
        assert_eq!(value.entries.len(), 1);
        assert_eq!(value.entries[0].version, 1);
    }

    #[test]
    fn merges_jsonl_lines_deterministically() {
        assert_eq!(merge_jsonl_lines("a\nb\n", "b\nc\n"), "a\nb\nc\n");
    }

    #[test]
    fn retry_backoff_matches_windows_baseline() {
        let mut state = RetryState::default();
        let now = Utc::now();
        assert_eq!(state.register_failure(now), Duration::from_secs(5));
        assert_eq!(state.register_failure(now), Duration::from_secs(15));
        assert_eq!(state.register_failure(now), Duration::from_secs(30));
        assert_eq!(state.register_failure(now), Duration::from_secs(60));
        assert_eq!(state.register_failure(now), Duration::from_secs(300));
        assert!(state.circuit_open);
    }

    #[test]
    fn public_error_redacts_secret_like_details() {
        let error = ServerPulseError::Authentication("password=top-secret rejected".to_owned());
        let detail = error.public_error().detail.expect("detail");
        assert!(!detail.contains("top-secret"));
        assert!(detail.contains("[REDACTED]"));
    }

    #[test]
    fn reads_legacy_windows_server_config() {
        let servers = parse_server_configs(
            r#"{"Version":1,"Servers":[{"Id":"3090","Label":"RTX 3090","SshTarget":"3090","HostName":"10.0.0.2","Port":22,"User":"alice","Monitored":true}]}"#,
        )
        .expect("legacy config should parse");
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].host, "3090");
        assert_eq!(servers[0].user.as_deref(), Some("alice"));
        assert_eq!(servers[0].port, Some(22));
        assert!(servers[0].passwordless);
    }

    #[test]
    fn agent_script_generation_and_substitution() {
        let script = generate_agent_script("srv-1", "My Server", "10.0.0.1", 10, 60, true, 3, "echo SAMPLE");
        assert!(script.contains("sp_interval=10"));
        assert!(script.contains("sp_retention_days=60"));
        assert!(script.contains("sp_server_id=\"srv-1\""));
        assert!(script.contains("sp_server_label=\"My Server\""));
        assert!(script.contains("echo SAMPLE"));
        // The effective scan flag follows the freeze constant even when the
        // caller requests the scan to be enabled.
        let expected_scan_flag = if DISK_ATTRIBUTION_FROZEN { 0 } else { 1 };
        assert!(script.contains(&format!("sp_scan_enabled={expected_scan_flag}")));
        assert!(script.contains("sp_scan_hour=3"));
        assert!(script.contains("m_d_keys"));
        assert!(script.contains("emit_disks"));
    }

    #[test]
    fn frozen_attribution_generation_is_disabled() {
        // Pins the code-level freeze: while DISK_ATTRIBUTION_FROZEN is on, no
        // generated remote script may schedule, transfer, or delete
        // attribution data — the feature is frozen, not removed.
        assert!(DISK_ATTRIBUTION_FROZEN);
        let script = generate_agent_script("srv-1", "My Server", "10.0.0.1", 10, 60, true, 3, "echo SAMPLE");
        assert!(script.contains("sp_scan_enabled=0"));
        let config = generate_agent_config("srv-1", "My Server", "10.0.0.1", 10, 60, true, 3);
        assert!(config.contains("scan_enabled=0"));
        let pull = generate_agent_pull_script(None);
        assert!(!pull.contains("__SP_ATTR_FILE__"));
        assert!(!pull.contains("attribution"));
        let clean = generate_agent_clean_script("2026-08-20T03:00");
        assert!(!clean.contains("attribution"));
    }

    #[test]
    fn agent_status_parsing() {
        let output = "SP_AGENT_INSTALLED=1\nSP_AGENT_STATUS=running\nSP_AGENT_PID=12345\nSP_AGENT_HB_AGE=5\n";
        let info = parse_agent_status_output(output, 30);
        assert_eq!(info.status, AgentStatus::Running);
        assert_eq!(info.pid, Some(12345));
        assert_eq!(info.heartbeat_age_seconds, Some(5));

        // Stale test
        let output_stale = "SP_AGENT_INSTALLED=1\nSP_AGENT_STATUS=running\nSP_AGENT_PID=12345\nSP_AGENT_HB_AGE=65\n";
        let info_stale = parse_agent_status_output(output_stale, 30);
        assert_eq!(info_stale.status, AgentStatus::Stale);

        // Not installed test
        let output_none = "SP_AGENT_INSTALLED=0\nSP_AGENT_STATUS=stopped\n";
        let info_none = parse_agent_status_output(output_none, 30);
        assert_eq!(info_none.status, AgentStatus::NotInstalled);
    }

    #[test]
    fn agent_pull_and_merge_day_entries() {
        let pull_output = r#"
__SP_FILE__2026-08-19
{"Version":2,"Record":{"Timestamp":"2026-08-19T10:00:00Z","SampleCount":12,"Servers":[{"Id":"s1","OnlineSamples":12,"CpuPercent":25.0}]}}
SP_AGENT_RECORD_FILES=1
__SP_DONE__
"#;
        let known = vec!["s1".to_string()];
        let pull_res = parse_agent_pull_output(pull_output, &known, None);
        assert_eq!(pull_res.pulled_lines, 1);
        assert_eq!(pull_res.entries.len(), 1);
        assert_eq!(pull_res.entries[0].utc_day, "2026-08-19");
        assert_eq!(pull_res.entries[0].utc_timestamp, "2026-08-19T10:00:00Z");

        let existing: Vec<String> = vec![];
        let (merged, stats) = merge_agent_day_entries(&existing, &pull_res.entries);
        assert_eq!(stats.added_minutes, 1);
        assert_eq!(merged.len(), 1);
        assert!(merged[0].contains("\"Timestamp\":\"2026-08-19T10:00:00Z\""));
    }

    const ATTR_LINE_A: &str = r#"{"kind":"diskAttribution","serverId":"s1","scannedAt":"2026-08-20T03:12:45Z","mount":"/data","device":"/dev/sdb1","fstype":"xfs","totalMib":3813357,"usedMib":2980276,"percent":78.15,"status":"ok","durationSeconds":5432,"skippedEntries":0,"users":[{"uid":"1000","name":"alice","usedMib":1234567}]}"#;

    #[test]
    fn parses_disk_attribution_line() {
        let record = parse_disk_attribution_line(ATTR_LINE_A).expect("record should parse");
        assert_eq!(record.server_id, "s1");
        assert_eq!(record.mount, "/data");
        assert_eq!(record.status, UserUsageStatus::Ok);
        assert_eq!(record.users.len(), 1);
        assert_eq!(record.users[0].name, "alice");
    }

    #[test]
    fn rejects_non_attribution_line() {
        let error = parse_disk_attribution_line(r#"{"Version":2,"Record":{}}"#).expect_err("must reject");
        assert_eq!(error.code(), "invalid_history");
    }

    #[test]
    fn merges_attribution_by_server_mount_and_time() {
        let line_b = ATTR_LINE_A.replace("\"mount\":\"/data\"", "\"mount\":\"/\"");
        let incoming = format!("{}\n{}\n", ATTR_LINE_A, line_b);
        let (merged, conflicts) = merge_attribution_lines(ATTR_LINE_A, &incoming);
        assert_eq!(conflicts, 0); // 完全重复的 A 是相同负载，不算冲突
        let count = merged.lines().count();
        assert_eq!(count, 2); // 完全重复的 A 只保留一条；不同 mount 的 B 保留
        let first: serde_json::Value = serde_json::from_str(merged.lines().next().unwrap()).unwrap();
        assert_eq!(first["mount"], serde_json::Value::String("/".to_owned())); // 按时间排序时同秒记录按 mount 排序
    }

    #[test]
    fn counts_conflicting_attribution_duplicates() {
        let conflicting = ATTR_LINE_A.replace("\"usedMib\":1234567", "\"usedMib\":999");
        let (merged, conflicts) = merge_attribution_lines(ATTR_LINE_A, &format!("{ATTR_LINE_A}\n{conflicting}\n"));
        assert_eq!(conflicts, 1); // 同键不同负载：计数并保留首见
        assert_eq!(merged.lines().count(), 1);
        let kept: serde_json::Value = serde_json::from_str(merged.trim()).unwrap();
        assert_eq!(kept["users"][0]["usedMib"], serde_json::json!(1234567.0));
    }

    fn history_line_with_stamp(stamp: &str) -> String {
        format!(
            r#"{{"Version":2,"Record":{{"Timestamp":"{stamp}","SampleCount":1,"Servers":[]}}}}"#
        )
    }

    #[test]
    fn filtered_reader_keeps_only_in_window_lines() {
        let text = format!(
            "{past}\n{inside}\n{future}\n{corrupt}\n",
            past = history_line_with_stamp("2026-08-20T00:00:00Z"),
            inside = history_line_with_stamp("2026-08-23T05:00:00Z"),
            future = history_line_with_stamp("2026-08-30T00:00:00Z"),
            corrupt = "{\"Version\":2,\"Record\":{\"Timestamp\":\"2026-08-23T06:00:00Z\",broken"
        );
        let reader = std::io::BufReader::new(text.as_bytes());
        let read = read_history_jsonl_filtered(
            reader,
            "2026-08-22T00:00:00",
            "2026-08-24T00:00:00",
        );
        assert_eq!(read.entries.len(), 1);
        assert_eq!(read.corrupt_lines, 1); // 窗口外的坏行不计数：从未解析
        let stamp = read.entries[0].record["Timestamp"].as_str().unwrap();
        assert_eq!(stamp, "2026-08-23T05:00:00Z");
    }

    #[test]
    fn filtered_reader_window_boundaries_are_half_open() {
        let text = format!(
            "{at_start}\n{at_end}\n",
            at_start = history_line_with_stamp("2026-08-23T05:00:00Z"),
            at_end = history_line_with_stamp("2026-08-24T00:00:00Z"),
        );
        let reader = std::io::BufReader::new(text.as_bytes());
        let read = read_history_jsonl_filtered(
            reader,
            "2026-08-23T05:00:00",
            "2026-08-24T00:00:00",
        );
        assert_eq!(read.entries.len(), 1);
        assert_eq!(
            read.entries[0].record["Timestamp"].as_str().unwrap(),
            "2026-08-23T05:00:00Z"
        );
    }

    #[test]
    fn filtered_reader_never_skips_offset_or_odd_stamps() {
        // Offset-stamped and non-ISO stamps must reach full parsing even when
        // their naive prefix is outside the window; the caller's exact
        // timezone-aware filter decides their fate.
        let offset_line = history_line_with_stamp("2026-08-30T23:00:00+08:00");
        let odd_line = r#"{"Version":2,"Record":{"Timestamp":"2026/08/30 23:00:00","SampleCount":1,"Servers":[]}}"#;
        let no_ts_line = r#"{"Version":2,"Record":{"SampleCount":1}}"#;
        let text = format!("{offset_line}\n{odd_line}\n{no_ts_line}\n");
        let reader = std::io::BufReader::new(text.as_bytes());
        let read =
            read_history_jsonl_filtered(reader, "2026-08-22T00:00:00", "2026-08-24T00:00:00");
        assert_eq!(read.entries.len(), 3);
        assert_eq!(read.corrupt_lines, 0);
    }

    #[test]
    fn naive_stamp_shape_requires_iso_layout() {
        assert!(is_naive_stamp_shape("2026-08-23T05:00:01"));
        assert!(!is_naive_stamp_shape("2026-8-23T05:00:01"));
        assert!(!is_naive_stamp_shape("2026/08/23 05:00:01"));
        assert!(!is_naive_stamp_shape("2026-08-23 05:00:01"));
        assert!(!is_naive_stamp_shape("2026-08-23T05:00"));
    }
}
