export type UserUsageStatus = 'ok' | 'partial' | 'unavailable'

export interface ServerConfig {
  id: string
  label: string
  host: string
  user?: string | null
  port?: number | null
  monitored: boolean
  passwordless: boolean
  hostKeyRequired?: boolean
}

export type HostKeyState = 'unknown' | 'trusted' | 'changed'

export interface HostKeyRecord {
  algorithm: string
  fingerprint: string
}

export interface HostKeyChallenge {
  challengeId: string
  server: string
  port: number
  keys: HostKeyRecord[]
  state: HostKeyState
}

export interface StartResult {
  serverId: string
  status: 'started' | 'verified' | 'host-key-required' | 'host-key-changed' | 'password-required' | 'authentication-failed' | string
  detail?: string | null
  hostKey?: HostKeyChallenge | null
}

export interface ApplyServerResult {
  servers: ServerConfig[]
  start: StartResult
}
export interface CpuUserUsage {
  uid: string
  name: string
  percent: number
  processCount?: number | null
}

export interface MemoryUserUsage {
  uid: string
  name: string
  usedMib: number
  percent: number | null
  processCount?: number | null
}

export interface GpuUserUsage {
  uid: string
  name: string
  usedMib: number
  percent: number | null
  processCount?: number | null
}

export interface GpuMetric {
  index: number
  name: string
  uuid: string | null
  utilization: number | null
  memoryUsedMib: number | null
  memoryTotalMib: number | null
  temperatureC: number | null
  powerDrawW: number | null
  powerLimitW: number | null
  fanPercent: number | null
  userMemoryStatus: UserUsageStatus
  userMemory: GpuUserUsage[]
  unmappedProcesses: number
}

export interface MetricSnapshot {
  hostname: string
  protocolVersion: number
  cpuPercent: number | null
  memoryTotalMib: number | null
  memoryUsedMib: number | null
  memoryPercent: number | null
  loadOne: number | null
  loadFive: number | null
  loadFifteen: number | null
  uptimeSeconds: number | null
  cpuUserStatus: UserUsageStatus
  cpuUsers: CpuUserUsage[]
  memoryUserStatus: UserUsageStatus
  memoryUsers: MemoryUserUsage[]
  gpus: GpuMetric[]
  disks: DiskMetric[]
}

export interface HistoryEntry {
  Version: number
  Record: Record<string, unknown>
}

export interface SshConfigInfo {
  path: string | null
  aliases: string[]
  candidates: ServerConfig[]
  error: string | null
}

export type AgentStatus = 'running' | 'stale' | 'stopped' | 'not_installed' | 'checking' | 'unknown'

export interface AgentServerState {
  id: string
  intervalSeconds: number
  retentionDays: number
  autoRestoreOnStartup?: boolean
  mergeCursorUtc?: string | null
  lastStatus: AgentStatus
  lastStatusAt?: string | null
  lastError?: string
  lastMergeAt?: string | null
  lastMergeSummary?: string | null
}

export interface AgentMergeResult {
  serverId: string
  status: string
  pulledLines: number
  addedMinutes: number
  updatedServers: number
  skippedServers: number
  corruptLines: number
  recordFiles: number
  cursorUtc?: string | null
  error?: string | null
}

export interface DiskMetric {
  device: string
  mount: string
  totalMib: number | null
  usedMib: number | null
  percent: number | null
  fsType: string
}

export interface DiskUserUsage {
  uid: string
  name: string
  usedMib: number
}

export interface DiskAttributionRecord {
  kind: string
  serverId: string
  scannedAt: string
  mount: string
  device?: string | null
  fsType?: string | null
  totalMib?: number | null
  usedMib?: number | null
  percent?: number | null
  status: UserUsageStatus
  durationSeconds?: number | null
  skippedEntries: number
  users: DiskUserUsage[]
}

export interface DiskScanStatusInfo {
  installed: boolean
  active: boolean
  pid?: number | null
  state: string
  startedAt?: string | null
  finishedAt?: string | null
  lastMount?: string | null
  lastFile?: string | null
}

export interface DiskScanTriggerResult {
  serverId: string
  status: 'launched' | 'already-running' | 'failed' | string
  detail?: string | null
}

