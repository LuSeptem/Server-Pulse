<script setup lang="ts">
import type { MetricSnapshot, ServerConfig } from '../types'

defineProps<{
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
</script>

<template>
  <article class="server-card">
    <header class="card-header">
      <div>
        <strong>{{ server.label }}</strong>
        <span class="muted">{{ server.host }}</span>
      </div>
      <span class="status-pill" :class="'status-' + status.split(':')[0]">{{ status }}</span>
    </header>

    <div v-if="snapshot" class="metrics-grid">
      <div class="metric">
        <span>CPU</span>
        <strong>{{ snapshot.cpuPercent != null ? snapshot.cpuPercent.toFixed(1) + '%' : '—' }}</strong>
      </div>
      <div class="metric">
        <span>MEM</span>
        <strong>{{ snapshot.memoryPercent != null ? snapshot.memoryPercent.toFixed(1) + '%' : '—' }}</strong>
      </div>
      <div class="metric">
        <span>GPU</span>
        <strong>{{ snapshot.gpus && snapshot.gpus.length ? snapshot.gpus.length : '0' }}</strong>
      </div>
      <div class="metric">
        <span>HOST</span>
        <strong :title="snapshot.hostname">{{ snapshot.hostname || server.host }}</strong>
      </div>
    </div>

    <!-- Detailed GPU breakdown if GPUs are present -->
    <div v-if="snapshot && snapshot.gpus && snapshot.gpus.length" class="gpu-summary-list">
      <div v-for="gpu in snapshot.gpus" :key="gpu.index" class="gpu-summary-row">
        <span class="gpu-label">GPU {{ gpu.index }}: {{ gpu.name }}</span>
        <span class="gpu-usage">
          {{ gpu.utilization != null ? gpu.utilization.toFixed(0) + '%' : '—' }} · 
          {{ gpu.memoryUsedMib != null ? (gpu.memoryUsedMib / 1024).toFixed(1) : '—' }}/{{ gpu.memoryTotalMib != null ? (gpu.memoryTotalMib / 1024).toFixed(0) : '—' }} GB
        </span>
      </div>
    </div>

    <p v-if="error" class="error-text">{{ error }}</p>

    <footer class="card-actions">
      <button v-if="status === 'stopped' || status === 'offline'" @click="$emit('start')">Start</button>
      <button v-else @click="$emit('stop')">Stop</button>
      <button @click="$emit('recheck')">Recheck</button>
    </footer>
  </article>
</template>
