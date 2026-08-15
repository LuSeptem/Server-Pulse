<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { LineChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
import { use } from 'echarts/core'
import { CanvasRenderer } from 'echarts/renderers'
import VChart from 'vue-echarts'
import { useMonitorStore } from '../stores/monitor'

use([LineChart, CanvasRenderer, GridComponent, LegendComponent, TooltipComponent])

const store = useMonitorStore()
const day = ref(new Date().toISOString().slice(0, 10))
const closeWindow = () => { void getCurrentWindow().close() }

const points = computed(() => store.history.map((entry) => {
  const record = entry.Record as {
    Timestamp?: string
    CpuPercent?: number | null
    MemoryPercent?: number | null
    Servers?: Array<{ CpuPercent?: number | null; MemoryPercent?: number | null }>
  }
  const server = record.Servers?.[0]
  return {
    timestamp: record.Timestamp ?? '',
    cpu: server?.CpuPercent ?? record.CpuPercent ?? null,
    memory: server?.MemoryPercent ?? record.MemoryPercent ?? null,
  }
}))

onMounted(() => store.loadHistory(day.value))

const option = computed(() => ({
  tooltip: { trigger: 'axis' },
  legend: { data: ['CPU', 'Memory'] },
  grid: { left: 42, right: 16, top: 40, bottom: 32 },
  xAxis: { type: 'category', data: points.value.map((point) => point.timestamp) },
  yAxis: { type: 'value', min: 0, max: 100 },
  series: [
    {
      name: 'CPU',
      type: 'line',
      connectNulls: false,
      data: points.value.map((point) => point.cpu),
    },
    {
      name: 'Memory',
      type: 'line',
      connectNulls: false,
      data: points.value.map((point) => point.memory),
    },
  ],
}))
</script>

<template>
  <section class="page-window">
    <header class="page-header">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>Usage history</h1>
      </div>
      <button @click="closeWindow">Close</button>
    </header>
    <label class="field">
      <span>Day</span>
      <input v-model="day" type="date" @change="store.loadHistory(day)" />
    </label>
    <p class="muted" v-if="store.historyCorruptLines">Ignored {{ store.historyCorruptLines }} malformed line(s).</p>
    <VChart class="history-chart" :option="option" autoresize />
    <p v-if="!store.history.length" class="empty-state">No history records for this day.</p>
  </section>
</template>
