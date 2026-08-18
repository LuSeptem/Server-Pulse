<script setup lang="ts">
import type { GpuMetric, MetricSnapshot, ServerConfig } from '../types'
import { useUserUsagePopup } from '../composables/useUserUsagePopup'

const props = defineProps<{
  server: ServerConfig
  snapshot?: MetricSnapshot
  status: string
  error?: string
}>()

defineEmits<{
  start: []
  stop: []
  recheck: []
}>()

const {
  currentTarget,
  isPinned,
  onTargetMouseEnter,
  onTargetMouseLeave,
  onTargetClick,
} = useUserUsagePopup()

function formatGpuName(name: string) {
  if (!name) return 'GPU'
  return name.replace(/^NVIDIA\s+GeForce\s+/i, 'NVIDIA ').replace(/^NVIDIA\s+/i, 'NVIDIA ')
}

function getVramPercent(gpu: GpuMetric) {
  if (gpu.memoryUsedMib != null && gpu.memoryTotalMib && gpu.memoryTotalMib > 0) {
    return Math.min(Math.max((gpu.memoryUsedMib / gpu.memoryTotalMib) * 100, 0), 100)
  }
  return 0
}

function isTargetActive(kind: 'cpu' | 'memory' | 'vram', gpuIndex?: number) {
  if (!currentTarget.value) return false
  return (
    currentTarget.value.serverId === props.server.id &&
    currentTarget.value.kind === kind &&
    currentTarget.value.gpuIndex === gpuIndex
  )
}

function handleCpuEnter(event: MouseEvent) {
  if (!props.snapshot) return
  onTargetMouseEnter(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'cpu',
    },
    event.currentTarget as HTMLElement
  )
}

function handleCpuClick(event: MouseEvent) {
  if (!props.snapshot) return
  onTargetClick(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'cpu',
    },
    event.currentTarget as HTMLElement
  )
}

function handleMemEnter(event: MouseEvent) {
  if (!props.snapshot) return
  onTargetMouseEnter(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'memory',
      totalMiB: props.snapshot.memoryTotalMib ?? 0,
    },
    event.currentTarget as HTMLElement
  )
}

function handleMemClick(event: MouseEvent) {
  if (!props.snapshot) return
  onTargetClick(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'memory',
      totalMiB: props.snapshot.memoryTotalMib ?? 0,
    },
    event.currentTarget as HTMLElement
  )
}

function handleGpuVramEnter(gpu: GpuMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetMouseEnter(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'vram',
      gpuIndex: gpu.index,
      gpuName: formatGpuName(gpu.name),
      totalMiB: gpu.memoryTotalMib ?? 0,
    },
    event.currentTarget as HTMLElement
  )
}

function handleGpuVramClick(gpu: GpuMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetClick(
    {
      serverId: props.server.id,
      serverLabel: props.server.label,
      kind: 'vram',
      gpuIndex: gpu.index,
      gpuName: formatGpuName(gpu.name),
      totalMiB: gpu.memoryTotalMib ?? 0,
    },
    event.currentTarget as HTMLElement
  )
}
</script>

<template>
  <article class="server-card">
    <header class="card-header">
      <div>
        <strong>{{ server.label }}</strong>
        <span class="muted server-meta-line">
          {{ server.host }}<template v-if="snapshot?.hostname && snapshot.hostname !== server.host"> · {{ snapshot.hostname }}</template><template v-if="snapshot?.gpus && snapshot.gpus.length"> · {{ snapshot.gpus.length }} GPU{{ snapshot.gpus.length > 1 ? 's' : '' }}</template>
        </span>
      </div>
      <span class="status-pill" :class="'status-' + status.split(':')[0]">{{ status }}</span>
    </header>

    <div v-if="snapshot" class="metrics-grid">
      <div
        class="metric is-interactive"
        :class="{
          'is-active': isTargetActive('cpu'),
          'is-pinned': isTargetActive('cpu') && isPinned
        }"
        title="查看 CPU 各用户占用 (点击可固定)"
        @mouseenter="handleCpuEnter"
        @mouseleave="onTargetMouseLeave"
        @click.stop="handleCpuClick"
      >
        <span>CPU</span>
        <strong>{{ snapshot.cpuPercent != null ? snapshot.cpuPercent.toFixed(1) + '%' : '—' }}</strong>
      </div>
      <div
        class="metric is-interactive"
        :class="{
          'is-active': isTargetActive('memory'),
          'is-pinned': isTargetActive('memory') && isPinned
        }"
        title="查看内存各用户占用 (点击可固定)"
        @mouseenter="handleMemEnter"
        @mouseleave="onTargetMouseLeave"
        @click.stop="handleMemClick"
      >
        <span>MEM</span>
        <strong>{{ snapshot.memoryPercent != null ? snapshot.memoryPercent.toFixed(1) + '%' : '—' }}</strong>
      </div>
    </div>

    <!-- GPU Mini Cards Grid (Multi-column responsive) -->
    <div v-if="snapshot && snapshot.gpus && snapshot.gpus.length" class="gpu-cards-grid">
      <div v-for="gpu in snapshot.gpus" :key="gpu.index" class="gpu-mini-card">
        <div class="gpu-card-header">
          <span class="gpu-name-tag" :title="gpu.name">GPU {{ gpu.index }} · {{ formatGpuName(gpu.name) }}</span>
          <span v-if="gpu.temperatureC != null" class="gpu-temp-tag" :class="{ 'temp-warm': gpu.temperatureC >= 80 }">
            {{ gpu.temperatureC }}°C
          </span>
        </div>

        <div class="gpu-card-util">
          <span class="gpu-util-value">
            {{ gpu.utilization != null ? gpu.utilization.toFixed(0) + '%' : '—' }}
          </span>
        </div>

        <div class="gpu-bar-track">
          <div
            class="gpu-bar-fill util-bar"
            :class="{ 'is-high': gpu.utilization != null && gpu.utilization >= 80 }"
            :style="{ width: (gpu.utilization != null ? Math.min(Math.max(gpu.utilization, 0), 100) : 0) + '%' }"
          />
        </div>

        <div
          class="gpu-card-vram-row is-interactive"
          :class="{
            'is-active': isTargetActive('vram', gpu.index),
            'is-pinned': isTargetActive('vram', gpu.index) && isPinned
          }"
          title="查看显存各用户占用 (点击可固定)"
          @mouseenter="handleGpuVramEnter(gpu, $event)"
          @mouseleave="onTargetMouseLeave"
          @click.stop="handleGpuVramClick(gpu, $event)"
        >
          <span class="vram-label">显存</span>
          <span class="vram-val">
            {{ gpu.memoryUsedMib != null ? (gpu.memoryUsedMib / 1024).toFixed(1) : '—' }} / {{ gpu.memoryTotalMib != null ? (gpu.memoryTotalMib / 1024).toFixed(1) : '—' }} GB
          </span>
        </div>

        <div class="gpu-bar-track">
          <div
            class="gpu-bar-fill vram-bar"
            :class="{ 'is-high': getVramPercent(gpu) >= 80 }"
            :style="{ width: getVramPercent(gpu) + '%' }"
          />
        </div>
      </div>
    </div>

    <p v-if="error && status !== 'online'" class="error-text">{{ error }}</p>

    <footer class="card-actions">
      <button v-if="status === 'stopped' || status === 'offline'" @click="$emit('start')">Start</button>
      <button v-else @click="$emit('stop')">Stop</button>
      <button @click="$emit('recheck')">Recheck</button>
    </footer>
  </article>
</template>
