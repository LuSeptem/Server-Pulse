<script setup lang="ts">
import { computed, onMounted, ref, reactive } from 'vue'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { LineChart } from 'echarts/charts'
import {
  GridComponent,
  LegendComponent,
  TooltipComponent,
  DataZoomComponent,
  TitleComponent,
} from 'echarts/components'
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import VChart from 'vue-echarts'
import { useMonitorStore } from '../stores/monitor'

use([
  LineChart,
  CanvasRenderer,
  GridComponent,
  LegendComponent,
  TooltipComponent,
  DataZoomComponent,
  TitleComponent,
])

function getLocalDateString(date = new Date()) {
  const y = date.getFullYear()
  const m = String(date.getMonth() + 1).padStart(2, '0')
  const d = String(date.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

const store = useMonitorStore()
const day = ref(getLocalDateString())
const selectedServerFilter = ref<string>('all')

type ChartViewMode = 'all' | 'cpu' | 'gpu_vram' | 'gpu_util' | 'gpu_temp' | 'users'
const chartViewModes = ref<Record<string, ChartViewMode>>({})

const closeWindow = () => { void getCurrentWindow().close() }

const shiftDay = (delta: number) => {
  const [y, m, d] = day.value.split('-').map(Number)
  const current = new Date(y, m - 1, d)
  if (isNaN(current.getTime())) return
  current.setDate(current.getDate() + delta)
  day.value = getLocalDateString(current)
  void store.loadHistory(day.value)
}

const setToday = () => {
  day.value = getLocalDateString()
  void store.loadHistory(day.value)
}

onMounted(() => {
  void store.loadHistory(day.value)
})

export interface UserUsageEntry {
  uid: string
  name: string
  percent?: number
  usedMib?: number
}

export interface CpuUserUsageInfo {
  status: string
  users: UserUsageEntry[]
}

export interface MemoryUserUsageInfo {
  status: string
  users: UserUsageEntry[]
}

export interface GpuUserMemoryInfo {
  status: string
  users: UserUsageEntry[]
}

interface GpuRecordInfo {
  index: number
  name: string
  utilization: (number | null)[]
  memoryUsedGb: (number | null)[]
  temperatureC: (number | null)[]
  totalMib: number | null
  userMemory: (GpuUserMemoryInfo | null)[]
}

export interface ServerHistoryRecord {
  id: string
  label: string
  host: string
  hostname: string
  timestamps: string[]
  displayTimes: string[]
  cpu: (number | null)[]
  memory: (number | null)[]
  cpuUsers: (CpuUserUsageInfo | null)[]
  memoryUsers: (MemoryUserUsageInfo | null)[]
  gpus: GpuRecordInfo[]
  avgCpu: string
  peakCpu: string
  avgMem: string
  peakMem: string
  sampleCount: number
  topCpuUsers: { name: string; uid: string; maxPercent: number; avgPercent: number }[]
  topMemoryUsers: { name: string; uid: string; maxGb: number; avgGb: number }[]
  topGpuUsers: { name: string; uid: string; gpuIndex: number; maxGb: number; avgGb: number }[]
}

const GPU_COLORS = [
  '#38bdf8', // Cyan
  '#a3e635', // Lime
  '#fbbf24', // Amber
  '#f472b6', // Pink
  '#c084fc', // Purple
  '#fb923c', // Orange
  '#34d399', // Emerald
  '#f87171', // Red
]

function parseCpuUsers(s: any): CpuUserUsageInfo | null {
  const usage = s.CpuUserUsage || s.cpuUserUsage || s.CpuUser || s.cpuUser
  if (!usage) return null
  const status = usage.Status || usage.status || 'ok'
  const rawList = Array.isArray(usage.Users) ? usage.Users : (Array.isArray(usage.users) ? usage.users : [])
  const users: UserUsageEntry[] = rawList
    .map((u: any): UserUsageEntry => ({
      uid: String(u.Uid ?? u.uid ?? ''),
      name: String(u.Name ?? u.name ?? 'user'),
      percent: typeof u.Percent === 'number' ? u.Percent : (typeof u.percent === 'number' ? u.percent : 0),
    }))
    .filter((u: UserUsageEntry) => (u.percent ?? 0) > 0.01)
    .sort((a: UserUsageEntry, b: UserUsageEntry) => (b.percent ?? 0) - (a.percent ?? 0))
  return { status, users }
}

function parseMemoryUsers(s: any): MemoryUserUsageInfo | null {
  const usage = s.MemoryUserUsage || s.memoryUserUsage || s.MemoryUser || s.memoryUser
  if (!usage) return null
  const status = usage.Status || usage.status || 'ok'
  const rawList = Array.isArray(usage.Users) ? usage.Users : (Array.isArray(usage.users) ? usage.users : [])
  const totalMib = s.MemoryTotalMiB || s.memoryTotalMib || s.TotalMiB || 0
  const users: UserUsageEntry[] = rawList
    .map((u: any): UserUsageEntry => {
      const usedMib = typeof u.UsedMiB === 'number' ? u.UsedMiB : (typeof u.usedMib === 'number' ? u.usedMib : 0)
      const percent = typeof u.Percent === 'number' ? u.Percent : (typeof u.percent === 'number' ? u.percent : (totalMib > 0 ? (usedMib / totalMib) * 100 : 0))
      return {
        uid: String(u.Uid ?? u.uid ?? ''),
        name: String(u.Name ?? u.name ?? 'user'),
        usedMib,
        percent,
      }
    })
    .filter((u: UserUsageEntry) => (u.usedMib ?? 0) > 1 || (u.percent ?? 0) > 0.01)
    .sort((a: UserUsageEntry, b: UserUsageEntry) => (b.usedMib ?? 0) - (a.usedMib ?? 0))
  return { status, users }
}

function parseGpuUserMemory(g: any): GpuUserMemoryInfo | null {
  const usage = g.UserMemory || g.userMemory || g.UserUsage || g.userUsage
  if (!usage) return null
  const status = usage.Status || usage.status || 'ok'
  const rawList = Array.isArray(usage.Users) ? usage.Users : (Array.isArray(usage.users) ? usage.users : [])
  const totalMib = g.memoryTotalMib || g.MemoryTotalMiB || 0
  const users: UserUsageEntry[] = rawList
    .map((u: any): UserUsageEntry => {
      const usedMib = typeof u.UsedMiB === 'number' ? u.UsedMiB : (typeof u.usedMib === 'number' ? u.usedMib : 0)
      const percent = typeof u.Percent === 'number' ? u.Percent : (typeof u.percent === 'number' ? u.percent : (totalMib > 0 ? (usedMib / totalMib) * 100 : 0))
      return {
        uid: String(u.Uid ?? u.uid ?? ''),
        name: String(u.Name ?? u.name ?? 'user'),
        usedMib,
        percent,
      }
    })
    .filter((u: UserUsageEntry) => (u.usedMib ?? 0) > 1 || (u.percent ?? 0) > 0.01)
    .sort((a: UserUsageEntry, b: UserUsageEntry) => (b.usedMib ?? 0) - (a.usedMib ?? 0))
  return { status, users }
}

function parseToLocalDate(timestamp: string): Date | null {
  if (!timestamp) return null
  try {
    if (timestamp.endsWith('Z') || timestamp.includes('+') || (timestamp.includes('-') && timestamp.indexOf('-', 8) > 0)) {
      const d = new Date(timestamp)
      if (!isNaN(d.getTime())) return d
    }
    const clean = timestamp.replace('T', ' ').replace(/\//g, '-')
    const parts = clean.split(/[- :]/).map(Number)
    if (parts.length >= 6) {
      const d = new Date(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5])
      if (!isNaN(d.getTime())) return d
    }
    const d = new Date(timestamp)
    if (!isNaN(d.getTime())) return d
  } catch {}
  return null
}

function formatLocalTimestamp(timestamp: string): { displayTime: string; fullTime: string } {
  const d = parseToLocalDate(timestamp)
  if (d) {
    const hours = String(d.getHours()).padStart(2, '0')
    const minutes = String(d.getMinutes()).padStart(2, '0')
    const seconds = String(d.getSeconds()).padStart(2, '0')
    const displayTime = `${hours}:${minutes}:${seconds}`
    const y = d.getFullYear()
    const m = String(d.getMonth() + 1).padStart(2, '0')
    const dayStr = String(d.getDate()).padStart(2, '0')
    const fullTime = `${y}-${m}-${dayStr} ${displayTime}`
    return { displayTime, fullTime }
  }
  return { displayTime: timestamp, fullTime: timestamp }
}

function getZoomRange(timestamps: string[]): { start: number; end: number } {
  if (!timestamps || timestamps.length <= 1) {
    return { start: 0, end: 100 }
  }
  const lastD = parseToLocalDate(timestamps[timestamps.length - 1])
  const firstD = parseToLocalDate(timestamps[0])
  if (!lastD || !firstD) return { start: 0, end: 100 }
  const lastTime = lastD.getTime()
  const firstTime = firstD.getTime()
  const totalDuration = lastTime - firstTime
  const twoHoursMs = 2 * 60 * 60 * 1000

  if (totalDuration <= twoHoursMs || isNaN(totalDuration) || totalDuration <= 0) {
    return { start: 0, end: 100 }
  }

  const targetTime = lastTime - twoHoursMs
  let targetIdx = 0
  for (let i = timestamps.length - 1; i >= 0; i--) {
    const d = parseToLocalDate(timestamps[i])
    if (d && d.getTime() < targetTime) {
      targetIdx = i
      break
    }
  }
  const startPercent = Math.max(0, Math.min(95, Math.round((targetIdx / timestamps.length) * 100)))
  return { start: startPercent, end: 100 }
}

const serverHistories = computed<ServerHistoryRecord[]>(() => {
  const map = new Map<string, {
    id: string
    label: string
    host: string
    hostname: string
    timestamps: string[]
    displayTimes: string[]
    cpu: (number | null)[]
    memory: (number | null)[]
    cpuUsers: (CpuUserUsageInfo | null)[]
    memoryUsers: (MemoryUserUsageInfo | null)[]
    gpusMap: Map<number, GpuRecordInfo>
  }>()

  for (const entry of store.history) {
    const rec = entry.Record as any
    if (!rec) continue
    const rawTimestamp = rec.Timestamp || ''
    const { displayTime, fullTime } = formatLocalTimestamp(rawTimestamp)

    const serversList = Array.isArray(rec.Servers) && rec.Servers.length > 0
      ? rec.Servers
      : [{
          Id: rec.ServerId || rec.Host || 'default',
          Label: rec.Label || rec.ServerId || 'Server',
          Host: rec.Host || 'localhost',
          Hostname: rec.Hostname || '',
          CpuPercent: rec.CpuPercent,
          CpuUserUsage: rec.CpuUserUsage,
          MemoryPercent: rec.MemoryPercent,
          MemoryUserUsage: rec.MemoryUserUsage,
          Gpus: rec.Gpus,
        }]

    for (const s of serversList) {
      const serverId = s.Id || s.Host || 'default'
      if (!map.has(serverId)) {
        map.set(serverId, {
          id: serverId,
          label: s.Label || serverId,
          host: s.Host || serverId,
          hostname: s.Hostname || '',
          timestamps: [],
          displayTimes: [],
          cpu: [],
          memory: [],
          cpuUsers: [],
          memoryUsers: [],
          gpusMap: new Map(),
        })
      }
      const item = map.get(serverId)!
      if (s.Hostname && !item.hostname) item.hostname = s.Hostname
      if (s.Label && (item.label === serverId || !item.label)) item.label = s.Label

      item.timestamps.push(fullTime)
      item.displayTimes.push(displayTime)
      item.cpu.push(typeof s.CpuPercent === 'number' ? s.CpuPercent : null)
      item.memory.push(typeof s.MemoryPercent === 'number' ? s.MemoryPercent : null)
      item.cpuUsers.push(parseCpuUsers(s))
      item.memoryUsers.push(parseMemoryUsers(s))

      const gpusList = Array.isArray(s.Gpus) ? s.Gpus : []
      for (const g of gpusList) {
        const idx = typeof g.index === 'number' ? g.index : (typeof g.Index === 'number' ? g.Index : 0)
        const name = g.name || g.Name || `GPU ${idx}`
        const util = typeof g.utilization === 'number' ? g.utilization : (typeof g.Utilization === 'number' ? g.Utilization : null)
        const usedMib = typeof g.memoryUsedMib === 'number' ? g.memoryUsedMib : (typeof g.MemoryUsedMiB === 'number' ? g.MemoryUsedMiB : null)
        const totalMib = typeof g.memoryTotalMib === 'number' ? g.memoryTotalMib : (typeof g.MemoryTotalMiB === 'number' ? g.MemoryTotalMiB : null)
        const tempC = typeof g.temperatureC === 'number' ? g.temperatureC : (typeof g.TemperatureC === 'number' ? g.TemperatureC : null)
        const usedGb = usedMib != null ? Number((usedMib / 1024).toFixed(2)) : null
        const gpuUserMem = parseGpuUserMemory(g)

        if (!item.gpusMap.has(idx)) {
          const prevLength = item.timestamps.length - 1
          item.gpusMap.set(idx, {
            index: idx,
            name,
            utilization: new Array(prevLength).fill(null),
            memoryUsedGb: new Array(prevLength).fill(null),
            temperatureC: new Array(prevLength).fill(null),
            totalMib,
            userMemory: new Array(prevLength).fill(null),
          })
        }
        const gpuRecord = item.gpusMap.get(idx)!
        if (totalMib != null && !gpuRecord.totalMib) gpuRecord.totalMib = totalMib
        if (name && (gpuRecord.name === `GPU ${idx}` || !gpuRecord.name)) gpuRecord.name = name

        while (gpuRecord.utilization.length < item.timestamps.length - 1) {
          gpuRecord.utilization.push(null)
          gpuRecord.memoryUsedGb.push(null)
          gpuRecord.temperatureC.push(null)
          gpuRecord.userMemory.push(null)
        }
        gpuRecord.utilization.push(util)
        gpuRecord.memoryUsedGb.push(usedGb)
        gpuRecord.temperatureC.push(tempC)
        gpuRecord.userMemory.push(gpuUserMem)
      }

      for (const gpuRecord of item.gpusMap.values()) {
        while (gpuRecord.utilization.length < item.timestamps.length) {
          gpuRecord.utilization.push(null)
          gpuRecord.memoryUsedGb.push(null)
          gpuRecord.temperatureC.push(null)
          gpuRecord.userMemory.push(null)
        }
      }
    }
  }

  const result: ServerHistoryRecord[] = []
  for (const s of map.values()) {
    const validCpu = s.cpu.filter((v): v is number => v !== null)
    const validMem = s.memory.filter((v): v is number => v !== null)
    const avgCpu = validCpu.length ? (validCpu.reduce((a, b) => a + b, 0) / validCpu.length).toFixed(1) + '%' : '—'
    const peakCpu = validCpu.length ? Math.max(...validCpu).toFixed(1) + '%' : '—'
    const avgMem = validMem.length ? (validMem.reduce((a, b) => a + b, 0) / validMem.length).toFixed(1) + '%' : '—'
    const peakMem = validMem.length ? Math.max(...validMem).toFixed(1) + '%' : '—'

    const gpus = Array.from(s.gpusMap.values()).sort((a, b) => a.index - b.index)

    // Compute Top CPU Users
    const cpuUserStats = new Map<string, { name: string; uid: string; vals: number[] }>()
    for (const info of s.cpuUsers) {
      if (info && info.users) {
        for (const u of info.users) {
          if (!cpuUserStats.has(u.name)) {
            cpuUserStats.set(u.name, { name: u.name, uid: u.uid, vals: [] })
          }
          cpuUserStats.get(u.name)!.vals.push(u.percent ?? 0)
        }
      }
    }
    const topCpuUsers = Array.from(cpuUserStats.values())
      .map((st) => ({
        name: st.name,
        uid: st.uid,
        maxPercent: st.vals.length ? Number(Math.max(...st.vals).toFixed(1)) : 0,
        avgPercent: st.vals.length ? Number((st.vals.reduce((a, b) => a + b, 0) / st.vals.length).toFixed(1)) : 0,
      }))
      .sort((a, b) => b.maxPercent - a.maxPercent)

    // Compute Top Memory Users
    const memUserStats = new Map<string, { name: string; uid: string; vals: number[] }>()
    for (const info of s.memoryUsers) {
      if (info && info.users) {
        for (const u of info.users) {
          if (!memUserStats.has(u.name)) {
            memUserStats.set(u.name, { name: u.name, uid: u.uid, vals: [] })
          }
          memUserStats.get(u.name)!.vals.push(u.usedMib ? u.usedMib / 1024 : 0)
        }
      }
    }
    const topMemoryUsers = Array.from(memUserStats.values())
      .map((st) => ({
        name: st.name,
        uid: st.uid,
        maxGb: st.vals.length ? Number(Math.max(...st.vals).toFixed(2)) : 0,
        avgGb: st.vals.length ? Number((st.vals.reduce((a, b) => a + b, 0) / st.vals.length).toFixed(2)) : 0,
      }))
      .sort((a, b) => b.maxGb - a.maxGb)

    // Compute Top GPU Users
    const gpuUserStats = new Map<string, { name: string; uid: string; gpuIndex: number; vals: number[] }>()
    for (const g of gpus) {
      for (const info of g.userMemory) {
        if (info && info.users) {
          for (const u of info.users) {
            const key = `${u.name}_gpu_${g.index}`
            if (!gpuUserStats.has(key)) {
              gpuUserStats.set(key, { name: u.name, uid: u.uid, gpuIndex: g.index, vals: [] })
            }
            gpuUserStats.get(key)!.vals.push(u.usedMib ? u.usedMib / 1024 : 0)
          }
        }
      }
    }
    const topGpuUsers = Array.from(gpuUserStats.values())
      .map((st) => ({
        name: st.name,
        uid: st.uid,
        gpuIndex: st.gpuIndex,
        maxGb: st.vals.length ? Number(Math.max(...st.vals).toFixed(2)) : 0,
        avgGb: st.vals.length ? Number((st.vals.reduce((a, b) => a + b, 0) / st.vals.length).toFixed(2)) : 0,
      }))
      .sort((a, b) => b.maxGb - a.maxGb)

    result.push({
      id: s.id,
      label: s.label,
      host: s.host,
      hostname: s.hostname,
      timestamps: s.timestamps,
      displayTimes: s.displayTimes,
      cpu: s.cpu,
      memory: s.memory,
      cpuUsers: s.cpuUsers,
      memoryUsers: s.memoryUsers,
      gpus,
      avgCpu,
      peakCpu,
      avgMem,
      peakMem,
      sampleCount: s.timestamps.length,
      topCpuUsers,
      topMemoryUsers,
      topGpuUsers,
    })
  }

  return result
})
const filteredServers = computed(() => {
  if (selectedServerFilter.value === 'all') {
    return serverHistories.value
  }
  return serverHistories.value.filter((s) => s.id === selectedServerFilter.value)
})

type HistoryChartKind = 'cpu' | 'gpu_vram' | 'gpu_util' | 'gpu_temp' | 'users'

interface PinnedHistoryPopupData {
  server: ServerHistoryRecord
  chartKind: HistoryChartKind
  dataIndex: number
  timestamp: string
  title: string
  statusLabel: string
  countLabel: string
  cpu?: number | null
  memory?: number | null
  cpuUsers?: UserUsageEntry[]
  memoryUsers?: UserUsageEntry[]
  gpuVrams?: { index: number; name: string; vram: number | null; totalGb: string; users: UserUsageEntry[] }[]
  gpuUtils?: { index: number; name: string; util: number | null }[]
  gpuTemps?: { index: number; name: string; temp: number | null }[]
  userVrams?: { name: string; vramGb: number }[]
  coords: { x: number; y: number }
}

const pinnedPopup = ref<PinnedHistoryPopupData | null>(null)
const pinnedExpanded = ref(false)
const chartLegendState = reactive<Record<string, Record<string, boolean>>>({})

function isSeriesVisible(serverId: string, kind: HistoryChartKind, seriesName: string): boolean {
  const key = `${serverId}_${kind}`
  const state = chartLegendState[key]
  if (!state) return true
  return state[seriesName] !== false
}

function handleLegendSelectChange(event: any, serverId: string, kind: HistoryChartKind) {
  if (!event || !event.selected) return
  const key = `${serverId}_${kind}`
  chartLegendState[key] = { ...event.selected }

  // If a popup is currently pinned for this server & chartKind, refresh its filtered data immediately!
  if (pinnedPopup.value && pinnedPopup.value.server.id === serverId && pinnedPopup.value.chartKind === kind) {
    const s = pinnedPopup.value.server
    const idx = pinnedPopup.value.dataIndex
    const coords = pinnedPopup.value.coords
    openPinnedPopup(s, idx, kind, coords.x, coords.y)
  }
}

function handleChartClick(event: any, server: ServerHistoryRecord, kind: HistoryChartKind) {
  if (!event) return

  // 1. Ignore clicks on legend or non-grid/series components
  if (event.componentType && event.componentType !== 'series' && event.componentType !== 'grid') {
    return
  }

  // 2. Check ZRender target properties (if user clicked on legend text or symbol)
  if (event.target) {
    const t = event.target as any
    if (
      t.type === 'legend' ||
      t.__legendItem != null ||
      t.name === 'legend' ||
      t.parent?.name === 'legend' ||
      t.parent?.__legendItem != null
    ) {
      return
    }
  }

  const mouseEvent = (event.event?.event || event.event || event) as MouseEvent
  const clientX = typeof mouseEvent.clientX === 'number' ? mouseEvent.clientX : window.innerWidth / 2 - 150
  const clientY = typeof mouseEvent.clientY === 'number' ? mouseEvent.clientY : 150

  const target = (mouseEvent.target as HTMLElement) || document.querySelector('.history-chart-canvas')
  const canvas = target?.closest('canvas') || target?.closest('.history-chart-canvas')
  const rect = canvas ? canvas.getBoundingClientRect() : { width: 600, height: 260 }
  const offsetY = typeof event.offsetY === 'number' ? event.offsetY : (mouseEvent.offsetY ?? 50)

  // 3. Ignore click if it's in the legend bar (top: 0..36px) or bottom datazoom slider (bottom: 38px)
  if (offsetY < 36 || (rect.height && offsetY > rect.height - 38)) {
    return
  }

  let dataIdx: number | null = null

  if (typeof event.dataIndex === 'number') {
    dataIdx = event.dataIndex
  } else {
    const offsetX = typeof event.offsetX === 'number' ? event.offsetX : (mouseEvent.offsetX ?? 0)
    const gridLeft = 45
    const gridRight = 20
    const gridWidth = Math.max(10, rect.width - gridLeft - gridRight)
    const clampedX = Math.max(0, Math.min(gridWidth, offsetX - gridLeft))
    const fraction = clampedX / gridWidth

    const zoom = getZoomRange(server.timestamps)
    const startFrac = zoom.start / 100
    const endFrac = zoom.end / 100
    const timelineFrac = startFrac + fraction * (endFrac - startFrac)

    dataIdx = Math.max(0, Math.min(server.timestamps.length - 1, Math.round(timelineFrac * (server.timestamps.length - 1))))
  }

  if (dataIdx == null || dataIdx < 0 || dataIdx >= server.timestamps.length) return
  const timestamp = server.timestamps[dataIdx]
  if (!timestamp) return

  if (
    pinnedPopup.value &&
    pinnedPopup.value.server.id === server.id &&
    pinnedPopup.value.chartKind === kind &&
    pinnedPopup.value.dataIndex === dataIdx
  ) {
    pinnedPopup.value = null
    return
  }

  const popupWidth = 300
  const popupHeight = 320
  const x = Math.min(Math.max(16, clientX + 12), window.innerWidth - popupWidth - 24)
  const y = Math.min(Math.max(16, clientY - 20), Math.max(16, window.innerHeight - popupHeight - 24))

  openPinnedPopup(server, dataIdx, kind, x, y)
}

function openPinnedPopup(server: ServerHistoryRecord, dataIdx: number, kind: HistoryChartKind, x: number, y: number) {
  const timestamp = server.timestamps[dataIdx]
  if (!timestamp) return

  let title = ''
  let statusLabel = '完整'
  let countLabel = ''
  let cpu: number | null = null
  let memory: number | null = null
  let cpuUsers: UserUsageEntry[] | undefined
  let memoryUsers: UserUsageEntry[] | undefined
  let gpuVrams: { index: number; name: string; vram: number | null; totalGb: string; users: UserUsageEntry[] }[] | undefined
  let gpuUtils: { index: number; name: string; util: number | null }[] | undefined
  let gpuTemps: { index: number; name: string; temp: number | null }[] | undefined
  let userVrams: { name: string; vramGb: number }[] | undefined

  if (kind === 'cpu') {
    const isCpuVisible = isSeriesVisible(server.id, 'cpu', 'CPU Utilization')
    const isMemVisible = isSeriesVisible(server.id, 'cpu', 'System Memory')

    cpu = isCpuVisible ? server.cpu[dataIdx] : null
    memory = isMemVisible ? server.memory[dataIdx] : null
    cpuUsers = isCpuVisible ? (server.cpuUsers[dataIdx]?.users || []) : []
    memoryUsers = isMemVisible ? (server.memoryUsers[dataIdx]?.users || []) : []

    if (isCpuVisible && isMemVisible) {
      title = `${server.label} · CPU & 内存`
      statusLabel = `CPU ${cpu != null ? cpu.toFixed(1) + '%' : '—'} · 内存 ${memory != null ? memory.toFixed(1) + '%' : '—'}`
      countLabel = `${cpuUsers.length + memoryUsers.length} 项用户占用`
    } else if (isCpuVisible) {
      title = `${server.label} · CPU 使用率`
      statusLabel = `CPU ${cpu != null ? cpu.toFixed(1) + '%' : '—'}`
      countLabel = `${cpuUsers.length} 项 CPU 占用`
    } else if (isMemVisible) {
      title = `${server.label} · 系统内存`
      statusLabel = `内存 ${memory != null ? memory.toFixed(1) + '%' : '—'}`
      countLabel = `${memoryUsers.length} 项内存占用`
    } else {
      title = `${server.label} · CPU & 内存`
      statusLabel = `已隐藏所有曲线`
      countLabel = `无可见数据`
    }
  } else if (kind === 'gpu_vram') {
    title = `${server.label} · GPU 显存占用`
    const visibleGpus = server.gpus.filter((g) => isSeriesVisible(server.id, 'gpu_vram', `GPU ${g.index}: ${g.name}`))
    gpuVrams = visibleGpus.map((g) => ({
      index: g.index,
      name: g.name,
      vram: g.memoryUsedGb[dataIdx],
      totalGb: g.totalMib ? (g.totalMib / 1024).toFixed(0) : '?',
      users: g.userMemory[dataIdx]?.users || [],
    }))
    const totalActiveUsers = gpuVrams.reduce((acc, g) => acc + g.users.length, 0)
    statusLabel = `${visibleGpus.length} 张可见 GPU`
    countLabel = `${totalActiveUsers} 位用户活跃`
  } else if (kind === 'gpu_util') {
    title = `${server.label} · GPU 核心利用率`
    const visibleGpus = server.gpus.filter((g) => isSeriesVisible(server.id, 'gpu_util', `GPU ${g.index}: ${g.name}`))
    gpuUtils = visibleGpus.map((g) => ({
      index: g.index,
      name: g.name,
      util: g.utilization[dataIdx],
    }))
    statusLabel = `${visibleGpus.length} 张可见 GPU`
    countLabel = `${gpuUtils.filter((g) => (g.util ?? 0) > 1).length} 张运行中`
  } else if (kind === 'gpu_temp') {
    title = `${server.label} · GPU 温度明细`
    const visibleGpus = server.gpus.filter((g) => isSeriesVisible(server.id, 'gpu_temp', `GPU ${g.index}: ${g.name}`))
    gpuTemps = visibleGpus.map((g) => ({
      index: g.index,
      name: g.name,
      temp: g.temperatureC[dataIdx],
    }))
    const maxTemp = gpuTemps.length ? Math.max(...gpuTemps.map((g) => g.temp ?? 0), 0) : 0
    statusLabel = `${visibleGpus.length} 张可见 GPU`
    countLabel = `最高 ${maxTemp}°C`
  } else if (kind === 'users') {
    title = `${server.label} · 各用户显存占用`
    const perUserVramThisTick = new Map<string, number>()
    for (const g of server.gpus) {
      const uMem = g.userMemory[dataIdx]
      if (uMem && uMem.users) {
        for (const u of uMem.users) {
          const usedGb = u.usedMib ? u.usedMib / 1024 : 0
          perUserVramThisTick.set(u.name, (perUserVramThisTick.get(u.name) || 0) + usedGb)
        }
      }
    }
    const allUserVrams = Array.from(perUserVramThisTick.entries())
      .map(([name, vramGb]) => ({ name, vramGb }))
      .filter((u) => u.vramGb > 0.01)
      .sort((a, b) => b.vramGb - a.vramGb)
    userVrams = allUserVrams.filter((u) => isSeriesVisible(server.id, 'users', u.name))
    statusLabel = `用户显存`
    countLabel = `${userVrams.length} 位用户活跃`
  }

  pinnedExpanded.value = false
  pinnedPopup.value = {
    server,
    chartKind: kind,
    dataIndex: dataIdx,
    timestamp,
    title,
    statusLabel,
    countLabel,
    cpu,
    memory,
    cpuUsers,
    memoryUsers,
    gpuVrams,
    gpuUtils,
    gpuTemps,
    userVrams,
    coords: { x, y },
  }
}

const getCpuMemOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
  const legendKey = `${server.id}_cpu`
  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(16, 24, 18, 0.96)',
      borderColor: '#2d4334',
      borderWidth: 1,
      padding: [10, 14],
      textStyle: { color: '#e2ede6', fontSize: 12 },
      formatter: (params: any[]) => {
        if (!params || !params.length) return ''
        const dataIdx = params[0].dataIndex
        const time = server.timestamps[dataIdx] || params[0].name
        let html = `<div style="font-weight:600;margin-bottom:6px;color:#8fd3a8;font-size:12.5px;">${time}</div>`
        for (const p of params) {
          if (p.value == null) continue
          html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin:3px 0;">
            <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
            <strong style="color:#ffffff;">${Number(p.value).toFixed(1)}%</strong>
          </div>`
        }

        const isCpuVisible = params.some((p) => p.seriesName === 'CPU Utilization')
        const isMemVisible = params.some((p) => p.seriesName === 'System Memory')

        const cpuU = server.cpuUsers[dataIdx]
        if (isCpuVisible && cpuU && cpuU.users && cpuU.users.length > 0) {
          const topCpu = cpuU.users.slice(0, 6)
          html += `<div style="margin-top:8px;padding-top:6px;border-top:1px solid rgba(255,255,255,0.08);font-size:11px;color:#9cb0a2;">
            <div style="font-weight:600;color:#7dd3fc;margin-bottom:3px;display:flex;justify-content:space-between;">
              <span>⚡ CPU 用户占用:</span>
              <span style="font-size:10px;color:#627568;">(${cpuU.users.length} 位活跃)</span>
            </div>`
          for (const u of topCpu) {
            html += `<div style="display:flex;justify-content:space-between;gap:12px;color:#c9d6ce;margin:2px 0;">
              <span>${u.name}${u.uid ? ' <span style="color:#728579;font-size:10px;">(' + u.uid + ')</span>' : ''}</span>
              <span style="color:#e6ece8;font-weight:500;">${(u.percent || 0).toFixed(1)}%</span>
            </div>`
          }
          if (cpuU.users.length > 6) {
            html += `<div style="font-size:10px;color:#627568;text-align:right;margin-top:2px;">点击图表查看全部 ${cpuU.users.length} 位用户</div>`
          }
          html += `</div>`
        }

        const memU = server.memoryUsers[dataIdx]
        if (isMemVisible && memU && memU.users && memU.users.length > 0) {
          const topMem = memU.users.slice(0, 6)
          html += `<div style="margin-top:6px;padding-top:6px;border-top:1px solid rgba(255,255,255,0.08);font-size:11px;color:#9cb0a2;">
            <div style="font-weight:600;color:#86efac;margin-bottom:3px;display:flex;justify-content:space-between;">
              <span>💾 系统内存 用户占用:</span>
              <span style="font-size:10px;color:#627568;">(${memU.users.length} 位活跃)</span>
            </div>`
          for (const u of topMem) {
            const gb = u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : (u.percent ? (u.percent).toFixed(1) + '%' : '0 GB')
            const pct = u.percent ? ` · ${u.percent.toFixed(1)}%` : ''
            html += `<div style="display:flex;justify-content:space-between;gap:12px;color:#c9d6ce;margin:2px 0;">
              <span>${u.name}${u.uid ? ' <span style="color:#728579;font-size:10px;">(' + u.uid + ')</span>' : ''}</span>
              <span style="color:#e6ece8;font-weight:500;">${gb}${pct}</span>
            </div>`
          }
          if (memU.users.length > 6) {
            html += `<div style="font-size:10px;color:#627568;text-align:right;margin-top:2px;">点击图表查看全部 ${memU.users.length} 位用户</div>`
          }
          html += `</div>`
        }

        html += `<div style="font-size:10px;color:#7e9185;margin-top:6px;padding-top:4px;border-top:1px dashed rgba(255,255,255,0.06);text-align:right;">📌 点击图表可固定明细</div>`
        return html
      },
    },
    legend: {
      data: ['CPU Utilization', 'System Memory'],
      selected: chartLegendState[legendKey] || undefined,
      textStyle: { color: '#a2b4a8', fontSize: 11 },
      top: 4,
      right: 12,
    },
    grid: { left: 45, right: 20, top: 38, bottom: 42 },
    xAxis: {
      type: 'category',
      data: server.displayTimes,
      axisLine: { lineStyle: { color: '#25352a' } },
      axisLabel: { color: '#7a8c80', fontSize: 11 },
    },
    yAxis: {
      type: 'value',
      min: 0,
      max: 100,
      axisLine: { show: false },
      axisLabel: { color: '#7a8c80', formatter: '{value}%' },
      splitLine: { lineStyle: { color: '#1c2820', type: 'dashed' } },
    },
    dataZoom: [
      { type: 'inside', start: zoom.start, end: zoom.end },
      {
        type: 'slider',
        start: zoom.start,
        end: zoom.end,
        height: 14,
        bottom: 4,
        borderColor: '#253329',
        fillerColor: 'rgba(133, 232, 157, 0.15)',
        handleStyle: { color: '#85e89d' },
        textStyle: { color: '#85968b', fontSize: 10 },
      },
    ],
    series: [
      {
        name: 'CPU Utilization',
        type: 'line',
        smooth: 0.2,
        showSymbol: false,
        itemStyle: { color: '#38bdf8' },
        lineStyle: { width: 2, color: '#38bdf8' },
        areaStyle: {
          color: {
            type: 'linear',
            x: 0,
            y: 0,
            x2: 0,
            y2: 1,
            colorStops: [
              { offset: 0, color: 'rgba(56, 189, 248, 0.22)' },
              { offset: 1, color: 'rgba(56, 189, 248, 0.0)' },
            ],
          },
        },
        data: server.cpu,
      },
      {
        name: 'System Memory',
        type: 'line',
        smooth: 0.2,
        showSymbol: false,
        itemStyle: { color: '#85e89d' },
        lineStyle: { width: 2, color: '#85e89d' },
        areaStyle: {
          color: {
            type: 'linear',
            x: 0,
            y: 0,
            x2: 0,
            y2: 1,
            colorStops: [
              { offset: 0, color: 'rgba(133, 232, 157, 0.20)' },
              { offset: 1, color: 'rgba(133, 232, 157, 0.0)' },
            ],
          },
        },
        data: server.memory,
      },
    ],
  }
}

const getGpuVramOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
  const legendKey = `${server.id}_gpu_vram`
  const maxVram = Math.max(
    ...server.gpus.map((g) => (g.totalMib ? g.totalMib / 1024 : 48)),
    10,
  )
  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(16, 24, 18, 0.96)',
      borderColor: '#2d4334',
      borderWidth: 1,
      padding: [10, 14],
      textStyle: { color: '#e2ede6', fontSize: 12 },
      formatter: (params: any[]) => {
        if (!params || !params.length) return ''
        const dataIdx = params[0].dataIndex
        const time = server.timestamps[dataIdx] || params[0].name
        let html = `<div style="font-weight:600;margin-bottom:6px;color:#8fd3a8;font-size:12.5px;">${time}</div>`
        for (const p of params) {
          if (p.value == null) continue
          const g = server.gpus.find((x) => `GPU ${x.index}: ${x.name}` === p.seriesName)
          const totalGb = g?.totalMib ? (g.totalMib / 1024).toFixed(0) : '?'
          html += `<div style="margin:4px 0 2px;">
            <div style="display:flex;align-items:center;justify-content:space-between;gap:14px;">
              <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
              <strong style="color:#ffffff;">${Number(p.value).toFixed(1)} / ${totalGb} GB</strong>
            </div>`

          if (g && g.userMemory && g.userMemory[dataIdx]?.users?.length) {
            const activeUsers = g.userMemory[dataIdx]!.users
            html += `<div style="padding-left:14px;margin-top:2px;font-size:11px;color:#9cb0a2;">`
            for (const u of activeUsers.slice(0, 5)) {
              const gb = u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : ''
              const pct = u.percent ? ` · ${u.percent.toFixed(1)}%` : ''
              html += `<div style="display:flex;justify-content:space-between;gap:10px;color:#b8c7be;margin:1px 0;">
                <span>👤 ${u.name}${u.uid ? ' <span style="color:#728579;font-size:10px;">(' + u.uid + ')</span>' : ''}</span>
                <span style="color:#85e89d;font-weight:500;">${gb}${pct}</span>
              </div>`
            }
            if (activeUsers.length > 5) {
              html += `<div style="font-size:10px;color:#627568;text-align:right;">+ 其它 ${activeUsers.length - 5} 位用户</div>`
            }
            html += `</div>`
          }
          html += `</div>`
        }
        html += `<div style="font-size:10px;color:#7e9185;margin-top:6px;padding-top:4px;border-top:1px dashed rgba(255,255,255,0.06);text-align:right;">📌 点击图表可固定明细</div>`
        return html
      },
    },
    legend: {
      data: server.gpus.map((g) => `GPU ${g.index}: ${g.name}`),
      selected: chartLegendState[legendKey] || undefined,
      textStyle: { color: '#a2b4a8', fontSize: 11 },
      top: 4,
      right: 12,
      type: 'scroll',
    },
    grid: { left: 45, right: 20, top: 38, bottom: 42 },
    xAxis: {
      type: 'category',
      data: server.displayTimes,
      axisLine: { lineStyle: { color: '#25352a' } },
      axisLabel: { color: '#7a8c80', fontSize: 11 },
    },
    yAxis: {
      type: 'value',
      min: 0,
      max: Math.ceil(maxVram),
      axisLine: { show: false },
      axisLabel: { color: '#7a8c80', formatter: '{value} GB' },
      splitLine: { lineStyle: { color: '#1c2820', type: 'dashed' } },
    },
    dataZoom: [
      { type: 'inside', start: zoom.start, end: zoom.end },
      {
        type: 'slider',
        start: zoom.start,
        end: zoom.end,
        height: 14,
        bottom: 4,
        borderColor: '#253329',
        fillerColor: 'rgba(56, 189, 248, 0.15)',
        handleStyle: { color: '#38bdf8' },
        textStyle: { color: '#85968b', fontSize: 10 },
      },
    ],
    series: server.gpus.map((g, i) => ({
      name: `GPU ${g.index}: ${g.name}`,
      type: 'line',
      smooth: 0.2,
      showSymbol: false,
      itemStyle: { color: GPU_COLORS[i % GPU_COLORS.length] },
      lineStyle: { width: 2, color: GPU_COLORS[i % GPU_COLORS.length] },
      data: g.memoryUsedGb,
    })),
  }
}

const getGpuUtilOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
  const legendKey = `${server.id}_gpu_util`
  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(16, 24, 18, 0.95)',
      borderColor: '#2d4334',
      borderWidth: 1,
      textStyle: { color: '#e2ede6', fontSize: 12 },
      formatter: (params: any[]) => {
        if (!params || !params.length) return ''
        const time = server.timestamps[params[0].dataIndex] || params[0].name
        let html = `<div style="font-weight:600;margin-bottom:4px;color:#8fd3a8;">${time}</div>`
        for (const p of params) {
          if (p.value == null) continue
          html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin:2px 0;">
            <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
            <strong style="color:#ffffff;">${Number(p.value).toFixed(0)}%</strong>
          </div>`
        }
        html += `<div style="font-size:10px;color:#7e9185;margin-top:6px;padding-top:4px;border-top:1px dashed rgba(255,255,255,0.06);text-align:right;">📌 点击图表可固定明细</div>`
        return html
      },
    },
    legend: {
      data: server.gpus.map((g) => `GPU ${g.index}: ${g.name}`),
      selected: chartLegendState[legendKey] || undefined,
      textStyle: { color: '#a2b4a8', fontSize: 11 },
      top: 4,
      right: 12,
      type: 'scroll',
    },
    grid: { left: 45, right: 20, top: 38, bottom: 42 },
    xAxis: {
      type: 'category',
      data: server.displayTimes,
      axisLine: { lineStyle: { color: '#25352a' } },
      axisLabel: { color: '#7a8c80', fontSize: 11 },
    },
    yAxis: {
      type: 'value',
      min: 0,
      max: 100,
      axisLine: { show: false },
      axisLabel: { color: '#7a8c80', formatter: '{value}%' },
      splitLine: { lineStyle: { color: '#1c2820', type: 'dashed' } },
    },
    dataZoom: [
      { type: 'inside', start: zoom.start, end: zoom.end },
      {
        type: 'slider',
        start: zoom.start,
        end: zoom.end,
        height: 14,
        bottom: 4,
        borderColor: '#253329',
        fillerColor: 'rgba(163, 230, 53, 0.15)',
        handleStyle: { color: '#a3e635' },
        textStyle: { color: '#85968b', fontSize: 10 },
      },
    ],
    series: server.gpus.map((g, i) => ({
      name: `GPU ${g.index}: ${g.name}`,
      type: 'line',
      smooth: 0.2,
      showSymbol: false,
      itemStyle: { color: GPU_COLORS[i % GPU_COLORS.length] },
      lineStyle: { width: 2, color: GPU_COLORS[i % GPU_COLORS.length] },
      data: g.utilization,
    })),
  }
}

const getGpuTempOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
  const legendKey = `${server.id}_gpu_temp`
  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(16, 24, 18, 0.95)',
      borderColor: '#2d4334',
      borderWidth: 1,
      textStyle: { color: '#e2ede6', fontSize: 12 },
      formatter: (params: any[]) => {
        if (!params || !params.length) return ''
        const time = server.timestamps[params[0].dataIndex] || params[0].name
        let html = `<div style="font-weight:600;margin-bottom:4px;color:#8fd3a8;">${time}</div>`
        for (const p of params) {
          if (p.value == null) continue
          html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin:2px 0;">
            <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
            <strong style="color:#ffffff;">${Number(p.value).toFixed(0)}°C</strong>
          </div>`
        }
        html += `<div style="font-size:10px;color:#7e9185;margin-top:6px;padding-top:4px;border-top:1px dashed rgba(255,255,255,0.06);text-align:right;">📌 点击图表可固定明细</div>`
        return html
      },
    },
    legend: {
      data: server.gpus.map((g) => `GPU ${g.index}: ${g.name}`),
      selected: chartLegendState[legendKey] || undefined,
      textStyle: { color: '#a2b4a8', fontSize: 11 },
      top: 4,
      right: 12,
      type: 'scroll',
    },
    grid: { left: 45, right: 20, top: 38, bottom: 42 },
    xAxis: {
      type: 'category',
      data: server.displayTimes,
      axisLine: { lineStyle: { color: '#25352a' } },
      axisLabel: { color: '#7a8c80', fontSize: 11 },
    },
    yAxis: {
      type: 'value',
      min: 0,
      max: 100,
      axisLine: { show: false },
      axisLabel: { color: '#7a8c80', formatter: '{value}°C' },
      splitLine: { lineStyle: { color: '#1c2820', type: 'dashed' } },
    },
    dataZoom: [
      { type: 'inside', start: zoom.start, end: zoom.end },
      {
        type: 'slider',
        start: zoom.start,
        end: zoom.end,
        height: 14,
        bottom: 4,
        borderColor: '#253329',
        fillerColor: 'rgba(251, 146, 60, 0.15)',
        handleStyle: { color: '#fb923c' },
        textStyle: { color: '#85968b', fontSize: 10 },
      },
    ],
    series: server.gpus.map((g, i) => ({
      name: `GPU ${g.index}: ${g.name}`,
      type: 'line',
      smooth: 0.2,
      showSymbol: false,
      itemStyle: { color: GPU_COLORS[i % GPU_COLORS.length] },
      lineStyle: { width: 2, color: GPU_COLORS[i % GPU_COLORS.length] },
      data: g.temperatureC,
    })),
  }
}

const getUserTimelineOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
  const legendKey = `${server.id}_users`
  const userMap = new Map<string, (number | null)[]>()
  for (let t = 0; t < server.timestamps.length; t++) {
    const perUserVramThisTick = new Map<string, number>()
    for (const g of server.gpus) {
      const uMem = g.userMemory[t]
      if (uMem && uMem.users) {
        for (const u of uMem.users) {
          const usedGb = u.usedMib ? u.usedMib / 1024 : 0
          perUserVramThisTick.set(u.name, (perUserVramThisTick.get(u.name) || 0) + usedGb)
        }
      }
    }
    for (const [userName, vramGb] of perUserVramThisTick.entries()) {
      if (!userMap.has(userName)) {
        userMap.set(userName, new Array(server.timestamps.length).fill(null))
      }
      userMap.get(userName)![t] = Number(vramGb.toFixed(2))
    }
  }

  const userKeys = Array.from(userMap.keys())
  const series = userKeys.map((userName, i) => ({
    name: userName,
    type: 'line',
    smooth: 0.2,
    showSymbol: false,
    itemStyle: { color: GPU_COLORS[i % GPU_COLORS.length] },
    lineStyle: { width: 2, color: GPU_COLORS[i % GPU_COLORS.length] },
    data: userMap.get(userName)!,
  }))

  return {
    backgroundColor: 'transparent',
    tooltip: {
      trigger: 'axis',
      backgroundColor: 'rgba(16, 24, 18, 0.96)',
      borderColor: '#2d4334',
      borderWidth: 1,
      textStyle: { color: '#e2ede6', fontSize: 12 },
      formatter: (params: any[]) => {
        if (!params || !params.length) return ''
        const time = server.timestamps[params[0].dataIndex] || params[0].name
        let html = `<div style="font-weight:600;margin-bottom:4px;color:#8fd3a8;">${time}</div>`
        for (const p of params) {
          if (p.value == null || p.value === 0) continue
          html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin:2px 0;">
            <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
            <strong style="color:#ffffff;">${Number(p.value).toFixed(2)} GB</strong>
          </div>`
        }
        html += `<div style="font-size:10px;color:#7e9185;margin-top:6px;padding-top:4px;border-top:1px dashed rgba(255,255,255,0.06);text-align:right;">📌 点击图表可固定明细</div>`
        return html
      },
    },
    legend: {
      data: userKeys,
      selected: chartLegendState[legendKey] || undefined,
      textStyle: { color: '#a2b4a8', fontSize: 11 },
      top: 4,
      right: 12,
      type: 'scroll',
    },
    grid: { left: 45, right: 20, top: 38, bottom: 42 },
    xAxis: {
      type: 'category',
      data: server.displayTimes,
      axisLine: { lineStyle: { color: '#25352a' } },
      axisLabel: { color: '#7a8c80', fontSize: 11 },
    },
    yAxis: {
      type: 'value',
      min: 0,
      axisLine: { show: false },
      axisLabel: { color: '#7a8c80', formatter: '{value} GB' },
      splitLine: { lineStyle: { color: '#1c2820', type: 'dashed' } },
    },
    dataZoom: [
      { type: 'inside', start: zoom.start, end: zoom.end },
      {
        type: 'slider',
        start: zoom.start,
        end: zoom.end,
        height: 14,
        bottom: 4,
        borderColor: '#253329',
        fillerColor: 'rgba(56, 189, 248, 0.15)',
        handleStyle: { color: '#38bdf8' },
        textStyle: { color: '#85968b', fontSize: 10 },
      },
    ],
    series,
  }
}
</script>

<template>
  <section class="page-window history-window">
    <!-- Pinned Detail Popup for Historical Samples (Aligned with Main View UserUsagePopup UI) -->
    <Teleport to="body">
      <div
        v-if="pinnedPopup"
        class="user-usage-popup is-pinned"
        :style="{
          left: `${pinnedPopup.coords.x}px`,
          top: `${pinnedPopup.coords.y}px`,
        }"
      >
        <header class="user-popup-header">
          <div class="user-popup-title-area">
            <span class="user-popup-title" :title="pinnedPopup.title">{{ pinnedPopup.title }}</span>
            <span class="user-popup-mode-badge pinned">
              ● 已固定 · {{ pinnedPopup.timestamp }}
            </span>
          </div>
          <button
            type="button"
            class="user-popup-close-btn"
            title="关闭 / 取消固定"
            @click="pinnedPopup = null"
          >
            ×
          </button>
        </header>

        <div class="user-popup-status-bar">
          <span class="user-popup-status status-ok">
            {{ pinnedPopup.statusLabel }}
          </span>
          <span class="user-popup-count">{{ pinnedPopup.countLabel }}</span>
        </div>

        <div class="user-popup-content">
          <!-- 1. CPU & Memory Chart Content -->
          <template v-if="pinnedPopup.chartKind === 'cpu'">
            <div v-if="!pinnedPopup.cpuUsers?.length && !pinnedPopup.memoryUsers?.length" class="user-popup-empty">
              当前时刻暂无用户活跃进程
            </div>
            <template v-else>
              <div v-if="pinnedPopup.cpuUsers?.length" class="user-rows-list">
                <div class="user-group-label">⚡ CPU 用户占用</div>
                <div
                  v-for="u in (pinnedExpanded ? pinnedPopup.cpuUsers : pinnedPopup.cpuUsers.slice(0, 6))"
                  :key="`cpu-${u.uid || u.name}`"
                  class="user-usage-row"
                >
                  <span class="user-name" :title="u.name">{{ u.name }}<span v-if="u.uid" class="user-uid-sub"> ({{ u.uid }})</span></span>
                  <span class="user-value">{{ (u.percent || 0).toFixed(1) }}%</span>
                </div>
              </div>

              <div v-if="pinnedPopup.memoryUsers?.length" class="user-rows-list" style="margin-top: 6px;">
                <div class="user-group-label">💾 系统内存 用户占用</div>
                <div
                  v-for="u in (pinnedExpanded ? pinnedPopup.memoryUsers : pinnedPopup.memoryUsers.slice(0, 6))"
                  :key="`mem-${u.uid || u.name}`"
                  class="user-usage-row"
                >
                  <span class="user-name" :title="u.name">{{ u.name }}<span v-if="u.uid" class="user-uid-sub"> ({{ u.uid }})</span></span>
                  <span class="user-value">
                    {{ u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : '' }}
                    {{ u.percent ? ` · ${u.percent.toFixed(1)}%` : '' }}
                  </span>
                </div>
              </div>

              <button
                v-if="(pinnedPopup.cpuUsers?.length || 0) > 6 || (pinnedPopup.memoryUsers?.length || 0) > 6"
                type="button"
                class="user-expand-toggle"
                @click="pinnedExpanded = !pinnedExpanded"
              >
                {{ pinnedExpanded ? '收起列表' : `+ 展开全部用户` }}
              </button>
            </template>
          </template>

          <!-- 2. GPU VRAM Chart Content -->
          <template v-else-if="pinnedPopup.chartKind === 'gpu_vram'">
            <div v-if="!pinnedPopup.gpuVrams?.length" class="user-popup-empty">
              当前时刻暂无显卡显存数据
            </div>
            <div v-else class="user-rows-list">
              <template v-for="g in pinnedPopup.gpuVrams" :key="g.index">
                <div class="user-usage-row gpu-row-header">
                  <span class="user-name gpu-name-text">GPU {{ g.index }}: {{ g.name }}</span>
                  <span class="user-value">{{ g.vram != null ? g.vram.toFixed(1) : '0' }} / {{ g.totalGb }} GB</span>
                </div>
                <div
                  v-for="u in (pinnedExpanded ? g.users : g.users.slice(0, 4))"
                  :key="`gpu-${g.index}-${u.uid || u.name}`"
                  class="user-usage-row sub-gpu-row"
                >
                  <span class="user-name">👤 {{ u.name }}<span v-if="u.uid" class="user-uid-sub"> ({{ u.uid }})</span></span>
                  <span class="user-value">
                    {{ u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : '' }}
                    {{ u.percent ? ` · ${u.percent.toFixed(1)}%` : '' }}
                  </span>
                </div>
                <div v-if="!g.users.length" class="user-popup-empty sub-empty">
                  无独立进程占用
                </div>
              </template>

              <button
                v-if="pinnedPopup.gpuVrams.some((g) => g.users.length > 4)"
                type="button"
                class="user-expand-toggle"
                @click="pinnedExpanded = !pinnedExpanded"
              >
                {{ pinnedExpanded ? '收起列表' : '+ 展开全部用户' }}
              </button>
            </div>
          </template>

          <!-- 3. GPU Core Utilization Content -->
          <template v-else-if="pinnedPopup.chartKind === 'gpu_util'">
            <div class="user-rows-list">
              <div
                v-for="g in pinnedPopup.gpuUtils"
                :key="g.index"
                class="user-usage-row"
              >
                <span class="user-name">GPU {{ g.index }}: {{ g.name }}</span>
                <span class="user-value">{{ g.util != null ? g.util.toFixed(0) : '0' }}%</span>
              </div>
            </div>
          </template>

          <!-- 4. GPU Temperature Content -->
          <template v-else-if="pinnedPopup.chartKind === 'gpu_temp'">
            <div class="user-rows-list">
              <div
                v-for="g in pinnedPopup.gpuTemps"
                :key="g.index"
                class="user-usage-row"
              >
                <span class="user-name">GPU {{ g.index }}: {{ g.name }}</span>
                <span class="user-value" style="color: #fb923c;">{{ g.temp != null ? g.temp.toFixed(0) : '0' }}°C</span>
              </div>
            </div>
          </template>

          <!-- 5. User VRAM Timeline Content -->
          <template v-else-if="pinnedPopup.chartKind === 'users'">
            <div v-if="!pinnedPopup.userVrams?.length" class="user-popup-empty">
              当前时刻暂无独立用户显存占用
            </div>
            <div v-else class="user-rows-list">
              <div
                v-for="u in (pinnedExpanded ? pinnedPopup.userVrams : pinnedPopup.userVrams.slice(0, 8))"
                :key="u.name"
                class="user-usage-row"
              >
                <span class="user-name">{{ u.name }}</span>
                <span class="user-value">{{ u.vramGb.toFixed(2) }} GB</span>
              </div>
              <button
                v-if="pinnedPopup.userVrams.length > 8"
                type="button"
                class="user-expand-toggle"
                @click="pinnedExpanded = !pinnedExpanded"
              >
                {{ pinnedExpanded ? '收起列表' : `+ 展开其它 ${pinnedPopup.userVrams.length - 8} 位用户` }}
              </button>
            </div>
          </template>
        </div>

        <footer class="user-popup-footer">
          * 点击图表任意区域或右上角关闭按钮可解除固定
        </footer>
      </div>
    </Teleport>

    <header class="page-header">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>Usage history</h1>
      </div>
      <div class="page-actions">
        <button class="primary-button" @click="setToday">Today</button>
        <button @click="closeWindow">Close</button>
      </div>
    </header>

    <div class="history-controls-card">
      <div class="controls-left">
        <div class="date-picker-group">
          <button class="icon-btn" title="Previous Day" @click="shiftDay(-1)">◄</button>
          <input
            v-model="day"
            type="date"
            class="history-date-input"
            @change="store.loadHistory(day)"
          />
          <button class="icon-btn" title="Next Day" @click="shiftDay(1)">►</button>
        </div>

        <div v-if="serverHistories.length > 1" class="server-filter-pills">
          <button
            type="button"
            class="filter-pill"
            :class="{ active: selectedServerFilter === 'all' }"
            @click="selectedServerFilter = 'all'"
          >
            All Servers ({{ serverHistories.length }})
          </button>
          <button
            v-for="s in serverHistories"
            :key="s.id"
            type="button"
            class="filter-pill"
            :class="{ active: selectedServerFilter === s.id }"
            @click="selectedServerFilter = s.id"
          >
            {{ s.label }}
          </button>
        </div>
      </div>

      <div class="controls-right">
        <span class="muted record-badge">{{ store.history.length }} samples</span>
        <span v-if="store.historyCorruptLines" class="corrupt-badge">Ignored {{ store.historyCorruptLines }} corrupt line(s)</span>
      </div>
    </div>

    <div v-if="!serverHistories.length" class="empty-state-card">
      <div class="empty-icon">📊</div>
      <h3>No history records found</h3>
      <p class="muted">No monitoring samples recorded on {{ day }}. Ensure background monitoring is running.</p>
    </div>

    <div class="history-servers-list">
      <article
        v-for="server in filteredServers"
        :key="server.id"
        class="server-history-section"
      >
        <header class="section-server-header">
          <div class="server-title-meta">
            <h2>{{ server.label }}</h2>
            <span class="muted host-tag">{{ server.host }}<template v-if="server.hostname && server.hostname !== server.host"> · {{ server.hostname }}</template></span>
          </div>

          <div class="server-stat-chips">
            <div class="stat-chip">
              <span class="chip-label">CPU Peak / Avg</span>
              <strong class="chip-val">{{ server.peakCpu }} / {{ server.avgCpu }}</strong>
            </div>
            <div class="stat-chip">
              <span class="chip-label">RAM Peak / Avg</span>
              <strong class="chip-val">{{ server.peakMem }} / {{ server.avgMem }}</strong>
            </div>
            <div v-if="server.gpus.length" class="stat-chip gpu-chip">
              <span class="chip-label">GPUs</span>
              <strong class="chip-val">{{ server.gpus.length }} Active</strong>
            </div>
          </div>
        </header>

        <div class="server-chart-tabs">
          <button
            type="button"
            class="tab-btn"
            :class="{ active: (chartViewModes[server.id] || 'all') === 'all' }"
            @click="chartViewModes[server.id] = 'all'"
          >
            All Charts
          </button>
          <button
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'cpu' }"
            @click="chartViewModes[server.id] = 'cpu'"
          >
            CPU & RAM
          </button>
          <button
            v-if="server.gpus.length"
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_vram' }"
            @click="chartViewModes[server.id] = 'gpu_vram'"
          >
            GPU VRAM (GB)
          </button>
          <button
            v-if="server.gpus.length"
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_util' }"
            @click="chartViewModes[server.id] = 'gpu_util'"
          >
            GPU Core (%)
          </button>
          <button
            v-if="server.gpus.length"
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_temp' }"
            @click="chartViewModes[server.id] = 'gpu_temp'"
          >
            GPU Temp (°C)
          </button>
          <button
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'users' }"
            @click="chartViewModes[server.id] = 'users'"
          >
            用户占用分析
          </button>
        </div>

        <div class="server-charts-stack">
          <div
            v-if="(chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'cpu'"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">CPU & System Memory Utilization (%)</span>
            </div>
            <VChart
              class="history-chart-canvas"
              :option="getCpuMemOption(server)"
              @click="handleChartClick($event, server, 'cpu')"
              @zr:click="handleChartClick($event, server, 'cpu')"
              @legendselectchanged="handleLegendSelectChange($event, server.id, 'cpu')"
              autoresize
            />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_vram')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU VRAM Usage (GB)</span>
            </div>
            <VChart
              class="history-chart-canvas"
              :option="getGpuVramOption(server)"
              @click="handleChartClick($event, server, 'gpu_vram')"
              @zr:click="handleChartClick($event, server, 'gpu_vram')"
              @legendselectchanged="handleLegendSelectChange($event, server.id, 'gpu_vram')"
              autoresize
            />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_util')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Core Utilization (%)</span>
            </div>
            <VChart
              class="history-chart-canvas"
              :option="getGpuUtilOption(server)"
              @click="handleChartClick($event, server, 'gpu_util')"
              @zr:click="handleChartClick($event, server, 'gpu_util')"
              @legendselectchanged="handleLegendSelectChange($event, server.id, 'gpu_util')"
              autoresize
            />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_temp')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Temperature (°C)</span>
            </div>
            <VChart
              class="history-chart-canvas"
              :option="getGpuTempOption(server)"
              @click="handleChartClick($event, server, 'gpu_temp')"
              @zr:click="handleChartClick($event, server, 'gpu_temp')"
              @legendselectchanged="handleLegendSelectChange($event, server.id, 'gpu_temp')"
              autoresize
            />
          </div>

          <div
            v-if="(chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'users'"
            class="user-attribution-container"
          >
            <div v-if="server.topGpuUsers.length" class="chart-card">
              <div class="chart-header">
                <span class="chart-title">用户显存占用变化曲线 (User VRAM Timeline - GB)</span>
              </div>
              <VChart
                class="history-chart-canvas"
                :option="getUserTimelineOption(server)"
                @click="handleChartClick($event, server, 'users')"
                @zr:click="handleChartClick($event, server, 'users')"
                @legendselectchanged="handleLegendSelectChange($event, server.id, 'users')"
                autoresize
              />
            </div>

            <div class="user-ranking-grid">
              <div v-if="server.gpus.length" class="user-ranking-card">
                <div class="user-ranking-title">
                  <span>🎮</span>
                  <span>GPU 显存占用排行 (Top GPU Users)</span>
                </div>
                <div v-if="server.topGpuUsers.length" class="user-ranking-list">
                  <div
                    v-for="u in server.topGpuUsers"
                    :key="`${u.name}_${u.gpuIndex}`"
                    class="user-ranking-item"
                  >
                    <div class="user-info-left">
                      <span class="user-name-text">{{ u.name }}</span>
                      <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
                      <span class="user-gpu-tag">GPU {{ u.gpuIndex }}</span>
                    </div>
                    <div class="user-value-right">
                      <span class="user-peak-val">{{ u.maxGb }} GB</span>
                      <span class="user-avg-val">均 {{ u.avgGb }} GB</span>
                    </div>
                  </div>
                </div>
                <div v-else class="no-users-hint">
                  暂无独立用户显存占用记录
                </div>
              </div>

              <div class="user-ranking-card">
                <div class="user-ranking-title">
                  <span>💾</span>
                  <span>系统内存占用排行 (Top Memory Users)</span>
                </div>
                <div v-if="server.topMemoryUsers.length" class="user-ranking-list">
                  <div
                    v-for="u in server.topMemoryUsers"
                    :key="u.name"
                    class="user-ranking-item"
                  >
                    <div class="user-info-left">
                      <span class="user-name-text">{{ u.name }}</span>
                      <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
                    </div>
                    <div class="user-value-right">
                      <span class="user-peak-val">{{ u.maxGb }} GB</span>
                      <span class="user-avg-val">均 {{ u.avgGb }} GB</span>
                    </div>
                  </div>
                </div>
                <div v-else class="no-users-hint">
                  暂无独立用户内存占用记录
                </div>
              </div>

              <div class="user-ranking-card">
                <div class="user-ranking-title">
                  <span>⚡</span>
                  <span>CPU 算力占用排行 (Top CPU Users)</span>
                </div>
                <div v-if="server.topCpuUsers.length" class="user-ranking-list">
                  <div
                    v-for="u in server.topCpuUsers"
                    :key="u.name"
                    class="user-ranking-item"
                  >
                    <div class="user-info-left">
                      <span class="user-name-text">{{ u.name }}</span>
                      <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
                    </div>
                    <div class="user-value-right">
                      <span class="user-peak-val">{{ u.maxPercent }}%</span>
                      <span class="user-avg-val">均 {{ u.avgPercent }}%</span>
                    </div>
                  </div>
                </div>
                <div v-else class="no-users-hint">
                  暂无独立用户 CPU 占用记录
                </div>
              </div>
            </div>
          </div>
        </div>
      </article>
    </div>
  </section>
</template>
