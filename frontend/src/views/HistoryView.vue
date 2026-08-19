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

type ChartViewMode = 'all' | 'cpu' | 'gpu_vram' | 'gpu_util' | 'gpu_temp'
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

interface GpuRecordInfo {
  index: number
  name: string
  utilization: (number | null)[]
  memoryUsedGb: (number | null)[]
  temperatureC: (number | null)[]
  totalMib: number | null
}

interface ServerHistoryRecord {
  id: string
  label: string
  host: string
  hostname: string
  timestamps: string[]
  displayTimes: string[]
  cpu: (number | null)[]
  memory: (number | null)[]
  gpus: GpuRecordInfo[]
  avgCpu: string
  peakCpu: string
  avgMem: string
  peakMem: string
  sampleCount: number
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

function getZoomRange(timestamps: string[]): { start: number; end: number } {
  if (!timestamps || timestamps.length <= 1) {
    return { start: 0, end: 100 }
  }
  const lastTime = new Date(timestamps[timestamps.length - 1]).getTime()
  const firstTime = new Date(timestamps[0]).getTime()
  const totalDuration = lastTime - firstTime
  const twoHoursMs = 2 * 60 * 60 * 1000

  if (totalDuration <= twoHoursMs || isNaN(totalDuration) || totalDuration <= 0) {
    return { start: 0, end: 100 }
  }

  const targetTime = lastTime - twoHoursMs
  let targetIdx = 0
  for (let i = timestamps.length - 1; i >= 0; i--) {
    const t = new Date(timestamps[i]).getTime()
    if (t < targetTime) {
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
    gpusMap: Map<number, GpuRecordInfo>
  }>()

  for (const entry of store.history) {
    const rec = entry.Record as any
    if (!rec) continue
    const timestamp = rec.Timestamp || ''
    let displayTime = timestamp
    try {
      const d = new Date(timestamp)
      if (!isNaN(d.getTime())) {
        displayTime = d.toLocaleTimeString([], { hour12: false })
      }
    } catch {}

    const serversList = Array.isArray(rec.Servers) && rec.Servers.length > 0
      ? rec.Servers
      : [{
          Id: rec.ServerId || rec.Host || 'default',
          Label: rec.Label || rec.ServerId || 'Server',
          Host: rec.Host || 'localhost',
          Hostname: rec.Hostname || '',
          CpuPercent: rec.CpuPercent,
          MemoryPercent: rec.MemoryPercent,
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
          gpusMap: new Map(),
        })
      }
      const item = map.get(serverId)!
      if (s.Hostname && !item.hostname) item.hostname = s.Hostname
      if (s.Label && (item.label === serverId || !item.label)) item.label = s.Label

      item.timestamps.push(timestamp)
      item.displayTimes.push(displayTime)
      item.cpu.push(typeof s.CpuPercent === 'number' ? s.CpuPercent : null)
      item.memory.push(typeof s.MemoryPercent === 'number' ? s.MemoryPercent : null)

      const gpusList = Array.isArray(s.Gpus) ? s.Gpus : []
      for (const g of gpusList) {
        const idx = typeof g.index === 'number' ? g.index : (typeof g.Index === 'number' ? g.Index : 0)
        const name = g.name || g.Name || `GPU ${idx}`
        const util = typeof g.utilization === 'number' ? g.utilization : (typeof g.Utilization === 'number' ? g.Utilization : null)
        const usedMib = typeof g.memoryUsedMib === 'number' ? g.memoryUsedMib : (typeof g.MemoryUsedMiB === 'number' ? g.MemoryUsedMiB : null)
        const totalMib = typeof g.memoryTotalMib === 'number' ? g.memoryTotalMib : (typeof g.MemoryTotalMiB === 'number' ? g.MemoryTotalMiB : null)
        const tempC = typeof g.temperatureC === 'number' ? g.temperatureC : (typeof g.TemperatureC === 'number' ? g.TemperatureC : null)
        const usedGb = usedMib != null ? Number((usedMib / 1024).toFixed(2)) : null

        if (!item.gpusMap.has(idx)) {
          const prevLength = item.timestamps.length - 1
          item.gpusMap.set(idx, {
            index: idx,
            name,
            utilization: new Array(prevLength).fill(null),
            memoryUsedGb: new Array(prevLength).fill(null),
            temperatureC: new Array(prevLength).fill(null),
            totalMib,
          })
        }
        const gpuRecord = item.gpusMap.get(idx)!
        if (totalMib != null && !gpuRecord.totalMib) gpuRecord.totalMib = totalMib
        if (name && (gpuRecord.name === `GPU ${idx}` || !gpuRecord.name)) gpuRecord.name = name

        while (gpuRecord.utilization.length < item.timestamps.length - 1) {
          gpuRecord.utilization.push(null)
          gpuRecord.memoryUsedGb.push(null)
          gpuRecord.temperatureC.push(null)
        }
        gpuRecord.utilization.push(util)
        gpuRecord.memoryUsedGb.push(usedGb)
        gpuRecord.temperatureC.push(tempC)
      }

      for (const gpuRecord of item.gpusMap.values()) {
        while (gpuRecord.utilization.length < item.timestamps.length) {
          gpuRecord.utilization.push(null)
          gpuRecord.memoryUsedGb.push(null)
          gpuRecord.temperatureC.push(null)
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

    result.push({
      id: s.id,
      label: s.label,
      host: s.host,
      hostname: s.hostname,
      timestamps: s.timestamps,
      displayTimes: s.displayTimes,
      cpu: s.cpu,
      memory: s.memory,
      gpus,
      avgCpu,
      peakCpu,
      avgMem,
      peakMem,
      sampleCount: s.timestamps.length,
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

const getCpuMemOption = (server: ServerHistoryRecord) => {
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
            <strong style="color:#ffffff;">${Number(p.value).toFixed(1)}%</strong>
          </div>`
        }
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
          const g = server.gpus.find((x) => `GPU ${x.index}: ${x.name}` === p.seriesName)
          const totalGb = g?.totalMib ? (g.totalMib / 1024).toFixed(0) : '?'
          html += `<div style="display:flex;align-items:center;justify-content:space-between;gap:14px;margin:2px 0;">
            <span><span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:${p.color};margin-right:6px;"></span>${p.seriesName}</span>
            <strong style="color:#ffffff;">${Number(p.value).toFixed(1)} / ${totalGb} GB</strong>
          </div>`
        }
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
</script>

<template>
  <section class="page-window history-window">
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

    <!-- Filter & Date Controls Bar -->
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

    <!-- Empty State -->
    <div v-if="!serverHistories.length" class="empty-state-card">
      <div class="empty-icon">📊</div>
      <h3>No history records found</h3>
      <p class="muted">No monitoring samples recorded on {{ day }}. Ensure background monitoring is running.</p>
    </div>

    <!-- Server History Sections -->
    <div class="history-servers-list">
      <article
        v-for="server in filteredServers"
        :key="server.id"
        class="server-history-section"
      >
        <!-- Server Header Bar with summary stats -->
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

        <!-- Sub-view tabs for this server (All / CPU / GPU VRAM / GPU Core / GPU Temp) -->
        <div v-if="server.gpus.length" class="server-chart-tabs">
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
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_vram' }"
            @click="chartViewModes[server.id] = 'gpu_vram'"
          >
            GPU VRAM (GB)
          </button>
          <button
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_util' }"
            @click="chartViewModes[server.id] = 'gpu_util'"
          >
            GPU Core (%)
          </button>
          <button
            type="button"
            class="tab-btn"
            :class="{ active: chartViewModes[server.id] === 'gpu_temp' }"
            @click="chartViewModes[server.id] = 'gpu_temp'"
          >
            GPU Temp (°C)
          </button>
        </div>

        <!-- Chart Grid for this Server -->
        <div class="server-charts-stack">
          <!-- 1. CPU & Memory Chart -->
          <div
            v-if="(chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'cpu'"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">CPU & System Memory Utilization (%)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getCpuMemOption(server)" autoresize />
          </div>

          <!-- 2. GPU VRAM Usage Breakdown Chart (Now above GPU Core) -->
          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_vram')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU VRAM Usage (GB)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuVramOption(server)" autoresize />
          </div>

          <!-- 3. GPU Core Utilization Breakdown Chart -->
          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_util')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Core Utilization (%)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuUtilOption(server)" autoresize />
          </div>

          <!-- 4. GPU Temperature Breakdown Chart -->
          <div
            v-if="server.gpus.length && ((chartViewModes[server.id] || 'all') === 'all' || chartViewModes[server.id] === 'gpu_temp')"
            class="chart-card"
          >
            <div class="chart-header">
              <span class="chart-title">Per-GPU Temperature (°C)</span>
            </div>
            <VChart class="history-chart-canvas" :option="getGpuTempOption(server)" autoresize />
          </div>
        </div>
      </article>
    </div>
  </section>
</template>
