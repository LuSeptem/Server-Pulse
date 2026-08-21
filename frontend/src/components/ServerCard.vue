<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue'
import type {
  DiskAttributionRecord,
  DiskMetric,
  DiskScanStatusInfo,
  GpuMetric,
  MetricSnapshot,
  ServerConfig,
} from '../types'
import { useUserUsagePopup } from '../composables/useUserUsagePopup'

const props = defineProps<{
  server: ServerConfig
  snapshot?: MetricSnapshot
  status: string
  error?: string
  diskAttribution?: DiskAttributionRecord[]
  diskScanStatus?: DiskScanStatusInfo
  scanError?: string | null
}>()

defineEmits<{
  start: []
  stop: []
  recheck: []
  scan: []
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

function isTargetActive(kind: 'cpu' | 'memory' | 'vram' | 'disk', gpuIndex?: number, mount?: string) {
  if (!currentTarget.value) return false
  return (
    currentTarget.value.serverId === props.server.id &&
    currentTarget.value.kind === kind &&
    currentTarget.value.gpuIndex === gpuIndex &&
    currentTarget.value.mount === mount
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

const disksExpanded = ref(false)

const worstDisk = computed(() => {
  const disks = (props.snapshot?.disks ?? []).filter((d) => d.percent != null)
  if (!disks.length) return null
  return disks.reduce((a, b) => ((b.percent ?? 0) > (a.percent ?? 0) ? b : a))
})

function formatCapacity(usedMib: number | null, totalMib: number | null) {
  const fmt = (v: number | null) => (v != null ? (v / 1048576).toFixed(1) : '—')
  return `${fmt(usedMib)} / ${fmt(totalMib)} TB`
}

function attributionFor(mount: string) {
  return (props.diskAttribution ?? []).find((record) => record.mount === mount) ?? null
}

// Records arrive sorted ascending by scannedAt; the freshness label must show
// the most recent scan, not the first row.
const latestScan = computed(() =>
  (props.diskAttribution ?? []).reduce<DiskAttributionRecord | null>(
    (acc, r) => (!acc || r.scannedAt > acc.scannedAt ? r : acc),
    null,
  ),
)

// Elapsed mm:ss while a scan is active, refreshed by a small interval that
// only runs while the scan is in progress.
const nowSeconds = ref(Math.floor(Date.now() / 1000))
let elapsedTimer: ReturnType<typeof setInterval> | null = null

const scanElapsed = computed(() => {
  const startedAt = props.diskScanStatus?.startedAt
  if (!startedAt || !props.diskScanStatus?.active) return null
  const startedMs = new Date(startedAt).getTime()
  if (Number.isNaN(startedMs)) return null
  // Depend on nowSeconds so the computed re-evaluates every timer tick.
  void nowSeconds.value
  const total = Math.max(0, Math.floor(Date.now() / 1000) - Math.floor(startedMs / 1000))
  const minutes = Math.floor(total / 60)
  const seconds = total % 60
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
})

function syncElapsedTimer() {
  const shouldRun = props.diskScanStatus?.active === true && props.diskScanStatus?.startedAt != null
  if (shouldRun && elapsedTimer === null) {
    elapsedTimer = setInterval(() => {
      nowSeconds.value = Math.floor(Date.now() / 1000)
    }, 1000)
  } else if (!shouldRun && elapsedTimer !== null) {
    clearInterval(elapsedTimer)
    elapsedTimer = null
  }
}

watch(
  () => [props.diskScanStatus?.active, props.diskScanStatus?.startedAt],
  () => syncElapsedTimer(),
  { immediate: true },
)

onUnmounted(() => {
  if (elapsedTimer !== null) {
    clearInterval(elapsedTimer)
    elapsedTimer = null
  }
})

function handleDiskEnter(disk: DiskMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetMouseEnter(
    { serverId: props.server.id, serverLabel: props.server.label, kind: 'disk', mount: disk.mount },
    event.currentTarget as HTMLElement
  )
}

function handleDiskClick(disk: DiskMetric, event: MouseEvent) {
  if (!props.snapshot) return
  onTargetClick(
    { serverId: props.server.id, serverLabel: props.server.label, kind: 'disk', mount: disk.mount },
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
      <div
        v-if="worstDisk"
        class="metric is-interactive"
        :class="{
          'is-active': isTargetActive('disk', undefined, worstDisk.mount),
          'is-pinned': isTargetActive('disk', undefined, worstDisk.mount) && isPinned
        }"
        title="查看磁盘各用户占用 (点击可固定)"
        @mouseenter="handleDiskEnter(worstDisk, $event)"
        @mouseleave="onTargetMouseLeave"
        @click.stop="handleDiskClick(worstDisk, $event)"
      >
        <span>DISK</span>
        <strong>{{ worstDisk.percent != null ? worstDisk.percent.toFixed(0) + '%' : '—' }} · {{ formatCapacity(worstDisk.usedMib, worstDisk.totalMib) }}</strong>
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

    <div v-if="snapshot && snapshot.disks && snapshot.disks.length" class="disk-section">
      <button type="button" class="disk-toggle" @click.stop="disksExpanded = !disksExpanded">
        {{ disksExpanded ? '收起磁盘' : `全部磁盘 (${snapshot.disks.length})` }}
      </button>
      <template v-if="disksExpanded">
        <div
          v-for="disk in snapshot.disks"
          :key="disk.mount"
          class="disk-row is-interactive"
          :class="{
            'is-active': isTargetActive('disk', undefined, disk.mount),
            'is-pinned': isTargetActive('disk', undefined, disk.mount) && isPinned
          }"
          @mouseenter="handleDiskEnter(disk, $event)"
          @mouseleave="onTargetMouseLeave"
          @click.stop="handleDiskClick(disk, $event)"
        >
          <span class="disk-mount" :title="disk.device">{{ disk.mount }}</span>
          <span class="disk-val">{{ disk.percent != null ? disk.percent.toFixed(0) + '%' : '—' }} · {{ formatCapacity(disk.usedMib, disk.totalMib) }}</span>
          <div class="gpu-bar-track">
            <div class="gpu-bar-fill vram-bar" :class="{ 'is-high': (disk.percent ?? 0) >= 80 }" :style="{ width: (disk.percent ?? 0) + '%' }" />
          </div>
        </div>
        <div class="disk-scan-row">
          <button
            type="button"
            :disabled="diskScanStatus?.active"
            @click.stop="$emit('scan')"
          >
            {{ diskScanStatus?.active
              ? `扫描中…${scanElapsed ? ' (' + scanElapsed + ')' : diskScanStatus.lastMount ? ' (' + diskScanStatus.lastMount + ')' : ''}`
              : '立即扫描' }}
          </button>
          <span v-if="latestScan" class="muted">
            来自 {{ new Date(latestScan.scannedAt).toLocaleDateString() }} 扫描
          </span>
          <span v-else class="muted">需服务端 agent 或手动扫描</span>
        </div>
        <p v-if="scanError" class="error-text">{{ scanError }}</p>
      </template>
    </div>

    <p v-if="error && status !== 'online'" class="error-text">{{ error }}</p>

    <footer class="card-actions">
      <button v-if="status === 'stopped' || status === 'offline'" @click="$emit('start')">Start</button>
      <button v-else @click="$emit('stop')">Stop</button>
      <button @click="$emit('recheck')">Recheck</button>
    </footer>
  </article>
</template>
