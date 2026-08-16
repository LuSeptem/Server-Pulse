export type UserUsageStatus = 'ok' | 'partial' | 'unavailable'

export interface ServerConfig {
  id: string
  label: string
  host: string
  user?: string | null
  port?: number | null
  monitored: boolean
  passwordless: boolean
}
export interface CpuUserUsage {
  uid: string
  name: string
  percent: number
}

export interface MemoryUserUsage {
  uid: string
  name: string
  usedMib: number
  percent: number | null
}

export interface GpuUserUsage {
  uid: string
  name: string
  usedMib: number
  percent: number | null
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
}

export interface HistoryEntry {
  Version: number
  Record: Record<string, unknown>
}
