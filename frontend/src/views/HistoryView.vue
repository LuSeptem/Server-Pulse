<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
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

interface PinnedHistoryPopupData {
  server: ServerHistoryRecord
  dataIndex: number
  timestamp: string
  cpu: number | null
  memory: number | null
  cpuUsers: UserUsageEntry[]
  memoryUsers: UserUsageEntry[]
  gpuList: {
    index: number
    name: string
    vram: number | null
    totalGb: string
    util: number | null
    temp: number | null
    users: UserUsageEntry[]
  }[]
  coords: { x: number; y: number }
}

const pinnedPopup = ref<PinnedHistoryPopupData | null>(null)
const pinnedPopupExpanded = ref({
  cpu: false,
  mem: false,
  gpu: false,
})

function handleChartClick(event: any, server: ServerHistoryRecord) {
  if (!event || event.dataIndex == null) return
  const dataIdx = event.dataIndex
  const timestamp = server.timestamps[dataIdx]
  if (!timestamp) return

  if (pinnedPopup.value && pinnedPopup.value.server.id === server.id && pinnedPopup.value.dataIndex === dataIdx) {
    pinnedPopup.value = null
    return
  }

  const mouseEvent = (event.event?.event || event.event) as MouseEvent | undefined
  const clientX = mouseEvent ? mouseEvent.clientX : window.innerWidth / 2 - 160
  const clientY = mouseEvent ? mouseEvent.clientY : 120

  const popupWidth = 340
  const popupHeight = 480
  const x = Math.min(Math.max(16, clientX + 16), window.innerWidth - popupWidth - 24)
  const y = Math.min(Math.max(16, clientY - 30), Math.max(16, window.innerHeight - popupHeight - 24))

  const gpuList = server.gpus.map((g) => ({
    index: g.index,
    name: g.name,
    vram: g.memoryUsedGb[dataIdx],
    totalGb: g.totalMib ? (g.totalMib / 1024).toFixed(0) : '?',
    util: g.utilization[dataIdx],
    temp: g.temperatureC[dataIdx],
    users: g.userMemory[dataIdx]?.users || [],
  }))

  pinnedPopup.value = {
    server,
    dataIndex: dataIdx,
    timestamp,
    cpu: server.cpu[dataIdx],
    memory: server.memory[dataIdx],
    cpuUsers: server.cpuUsers[dataIdx]?.users || [],
    memoryUsers: server.memoryUsers[dataIdx]?.users || [],
    gpuList,
    coords: { x, y },
  }
}

const getCpuMemOption = (server: ServerHistoryRecord) => {
  const zoom = getZoomRange(server.timestamps)
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

        const cpuU = server.cpuUsers[dataIdx]
        if (cpuU && cpuU.users && cpuU.users.length > 0) {
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
        if (memU && memU.users && memU.users.length > 0) {
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
    <!-- Pinned Detail Popup for Historical Samples -->
    <div
      v-if="pinnedPopup"
      class="user-usage-popup history-pinned-popup is-pinned"
      :style="{
        left: `${pinnedPopup.coords.x}px`,
        top: `${pinnedPopup.coords.y}px`,
      }"
    >
      <div class="user-popup-header">
        <div class="user-popup-title-area">
          <div class="user-popup-title">{{ pinnedPopup.server.label }} · 历史采样明细</div>
          <div class="user-popup-mode-badge pinned">📌 已固定 · {{ pinnedPopup.timestamp }}</div>
        </div>
        <button type="button" class="user-popup-close-btn" title="关闭固定" @click="pinnedPopup = null">✕</button>
      </div>

      <div class="user-popup-status-bar">
        <span class="user-popup-status">CPU: {{ pinnedPopup.cpu != null ? pinnedPopup.cpu.toFixed(1) + '%' : '—' }} · 内存: {{ pinnedPopup.memory != null ? pinnedPopup.memory.toFixed(1) + '%' : '—' }}</span>
        <span class="muted">{{ pinnedPopup.gpuList.length }} GPUs</span>
      </div>

      <div class="history-popup-scroll">
        <!-- CPU Users -->
        <div v-if="pinnedPopup.cpuUsers.length" class="popup-user-section">
          <div class="popup-section-header">
            <span class="popup-section-title">⚡ CPU 用户占用</span>
            <span class="popup-count-badge">{{ pinnedPopup.cpuUsers.length }} 位活跃</span>
          </div>
          <div class="popup-user-list">
            <div
              v-for="u in (pinnedPopupExpanded.cpu ? pinnedPopup.cpuUsers : pinnedPopup.cpuUsers.slice(0, 5))"
              :key="u.name"
              class="user-row"
            >
              <div class="user-row-name">
                <span>{{ u.name }}</span>
                <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
              </div>
              <strong class="user-row-value">{{ (u.percent || 0).toFixed(1) }}%</strong>
            </div>
            <button
              v-if="pinnedPopup.cpuUsers.length > 5"
              type="button"
              class="user-expand-btn"
              @click="pinnedPopupExpanded.cpu = !pinnedPopupExpanded.cpu"
            >
              {{ pinnedPopupExpanded.cpu ? '收起' : `+ 展开其它 ${pinnedPopup.cpuUsers.length - 5} 位用户` }}
            </button>
          </div>
        </div>

        <!-- Memory Users -->
        <div v-if="pinnedPopup.memoryUsers.length" class="popup-user-section">
          <div class="popup-section-header">
            <span class="popup-section-title">💾 系统内存 用户占用</span>
            <span class="popup-count-badge">{{ pinnedPopup.memoryUsers.length }} 位活跃</span>
          </div>
          <div class="popup-user-list">
            <div
              v-for="u in (pinnedPopupExpanded.mem ? pinnedPopup.memoryUsers : pinnedPopup.memoryUsers.slice(0, 5))"
              :key="u.name"
              class="user-row"
            >
              <div class="user-row-name">
                <span>{{ u.name }}</span>
                <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
              </div>
              <strong class="user-row-value">
                {{ u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : '' }}
                {{ u.percent ? '· ' + u.percent.toFixed(1) + '%' : '' }}
              </strong>
            </div>
            <button
              v-if="pinnedPopup.memoryUsers.length > 5"
              type="button"
              class="user-expand-btn"
              @click="pinnedPopupExpanded.mem = !pinnedPopupExpanded.mem"
            >
              {{ pinnedPopupExpanded.mem ? '收起' : `+ 展开其它 ${pinnedPopup.memoryUsers.length - 5} 位用户` }}
            </button>
          </div>
        </div>

        <!-- GPU Users -->
        <div v-if="pinnedPopup.gpuList.length" class="popup-user-section">
          <div class="popup-section-header">
            <span class="popup-section-title">🎮 GPU 显存及用户占用</span>
          </div>
          <div class="popup-gpu-stack">
            <div
              v-for="g in pinnedPopup.gpuList"
              :key="g.index"
              class="popup-gpu-card"
            >
              <div class="popup-gpu-header">
                <span class="popup-gpu-title">GPU {{ g.index }}: {{ g.name }}</span>
                <span class="popup-gpu-vram">{{ g.vram != null ? g.vram.toFixed(1) : '0' }} / {{ g.totalGb }} GB</span>
              </div>
              <div v-if="g.users.length" class="popup-user-list sub-list">
                <div
                  v-for="u in g.users"
                  :key="u.name"
                  class="user-row sub-row"
                >
                  <div class="user-row-name">
                    <span>👤 {{ u.name }}</span>
                    <span v-if="u.uid" class="user-uid-pill">{{ u.uid }}</span>
                  </div>
                  <strong class="user-row-value">
                    {{ u.usedMib ? (u.usedMib / 1024).toFixed(1) + ' GB' : '' }}
                    {{ u.percent ? '· ' + u.percent.toFixed(1) + '%' : '' }}
                  </strong>
                </div>
              </div>
              <div v-else class="empty-gpu-hint">无独立进程占用</div>
            </div>
          </div>
        </div>
      </div>
    </div>

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
            <VChart class="history-chart-canvas" :option="getCpuMemOption(server)" @click="handleChartClick($event, server)" autoresize />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_vram')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU VRAM Usage (GB)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuVramOption(server)" @click="handleChartClick($event, server)" autoresize />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_util')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Core Utilization (%)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuUtilOption(server)" @click="handleChartClick($event, server)" autoresize />
          </div>

          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_temp')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Temperature (°C)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuTempOption(server)" @click="handleChartClick($event, server)" autoresize />
          </div>

          <div
            v-if="(chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'users'"
            class="user-attribution-container"
          >
            <div v-if="server.topGpuUsers.length" class="chart-card">
              <div class="chart-header">
                <span class="chart-title">用户显存占用变化曲线 (User VRAM Timeline - GB)</span>
              </div>
              <VChart class="history-chart-canvas" :option="getUserTimelineOption(server)" @click="handleChartClick($event, server)" autoresize />
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
