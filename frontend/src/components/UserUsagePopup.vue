<script setup lang="ts">
import { computed } from 'vue'
import type { MetricSnapshot, UserUsageStatus } from '../types'
import type { UserUsageTargetInfo } from '../composables/useUserUsagePopup'

const props = defineProps<{
  target: UserUsageTargetInfo | null
  snapshot?: MetricSnapshot
  isPinned: boolean
  expanded: boolean
  coords: { x: number; y: number }
}>()

const emit = defineEmits<{
  close: []
  toggleExpand: []
  mouseenter: []
  mouseleave: []
}>()

interface FormattedUserRow {
  key: string
  name: string
  displayValue: string
  sortValue: number
}

const title = computed(() => {
  if (!props.target) return ''
  if (props.target.kind === 'cpu') {
    return `${props.target.serverLabel} · CPU · 用户占用`
  }
  if (props.target.kind === 'memory') {
    return `${props.target.serverLabel} · MEM · 用户占用`
  }
  const gpuName = props.target.gpuName ? ` ${props.target.gpuName}` : ''
  return `${props.target.serverLabel} · GPU ${props.target.gpuIndex ?? 0}${gpuName} · 显存占用`
})

const status = computed<UserUsageStatus>(() => {
  if (!props.snapshot || !props.target) return 'unavailable'
  if (props.target.kind === 'cpu') {
    return props.snapshot.cpuUserStatus ?? 'unavailable'
  }
  if (props.target.kind === 'memory') {
    return props.snapshot.memoryUserStatus ?? 'unavailable'
  }
  const gpu = props.snapshot.gpus?.find((g) => g.index === props.target?.gpuIndex)
  return gpu?.userMemoryStatus ?? 'unavailable'
})

const statusLabel = computed(() => {
  switch (status.value) {
    case 'ok':
      return '完整'
    case 'partial':
      return '部分未映射'
    default:
      return '不可用'
  }
})

const userRows = computed<FormattedUserRow[]>(() => {
  if (!props.snapshot || !props.target) return []

  if (props.target.kind === 'cpu') {
    const users = props.snapshot.cpuUsers || []
    return users
      .map((u) => ({
        key: `cpu-${u.uid || u.name}`,
        name: u.name || `UID ${u.uid}`,
        displayValue: `${u.percent.toFixed(1)}%`,
        sortValue: u.percent,
      }))
      .filter((r) => r.sortValue > 0.01)
      .sort((a, b) => b.sortValue - a.sortValue)
  }

  if (props.target.kind === 'memory') {
    const users = props.snapshot.memoryUsers || []
    const total = props.snapshot.memoryTotalMib || 0
    return users
      .map((u) => {
        const pct = u.percent != null ? u.percent : total > 0 ? (u.usedMib / total) * 100 : 0
        return {
          key: `mem-${u.uid || u.name}`,
          name: u.name || `UID ${u.uid}`,
          displayValue: `${(u.usedMib / 1024).toFixed(1)} GB · ${pct.toFixed(1)}%`,
          sortValue: u.usedMib,
        }
      })
      .filter((r) => r.sortValue > 0.01)
      .sort((a, b) => b.sortValue - a.sortValue)
  }

  // VRAM
  const gpu = props.snapshot.gpus?.find((g) => g.index === props.target?.gpuIndex)
  if (!gpu) return []
  const users = gpu.userMemory || []
  const total = gpu.memoryTotalMib || 0
  return users
    .map((u) => {
      const pct = u.percent != null ? u.percent : total > 0 ? (u.usedMib / total) * 100 : 0
      return {
        key: `gpu-${gpu.index}-${u.uid || u.name}`,
        name: u.name || `UID ${u.uid}`,
        displayValue: `${(u.usedMib / 1024).toFixed(1)} GB · ${pct.toFixed(1)}%`,
        sortValue: u.usedMib,
      }
    })
    .filter((r) => r.sortValue > 0.01)
    .sort((a, b) => b.sortValue - a.sortValue)
})

const visibleRows = computed(() => {
  if (props.expanded) return userRows.value
  return userRows.value.slice(0, 8)
})

const systemRow = computed(() => {
  if (!props.snapshot || !props.target || status.value === 'unavailable') {
    return null
  }
  if (props.target.kind === 'cpu') {
    const totalCpu = props.snapshot.cpuPercent || 0
    const usersSum = userRows.value.reduce((acc, r) => acc + r.sortValue, 0)
    const sys = Math.max(0, totalCpu - usersSum)
    return {
      name: '系统 / 未归属',
      displayValue: `${sys.toFixed(1)}%`,
    }
  }
  if (props.target.kind === 'memory') {
    const totalUsed = props.snapshot.memoryUsedMib || 0
    const totalMem = props.snapshot.memoryTotalMib || 0
    const usersSum = userRows.value.reduce((acc, r) => acc + r.sortValue, 0)
    const sys = Math.max(0, totalUsed - usersSum)
    const pct = totalMem > 0 ? (sys / totalMem) * 100 : 0
    return {
      name: '系统 / 未归属',
      displayValue: `${(sys / 1024).toFixed(1)} GB · ${pct.toFixed(1)}%`,
    }
  }
  // VRAM
  const gpu = props.snapshot.gpus?.find((g) => g.index === props.target?.gpuIndex)
  if (!gpu) return null
  const totalUsed = gpu.memoryUsedMib || 0
  const totalVram = gpu.memoryTotalMib || 0
  const usersSum = userRows.value.reduce((acc, r) => acc + r.sortValue, 0)
  const sys = Math.max(0, totalUsed - usersSum)
  const pct = totalVram > 0 ? (sys / totalVram) * 100 : 0
  return {
    name: '系统 / 驱动未归属',
    displayValue: `${(sys / 1024).toFixed(1)} GB · ${pct.toFixed(1)}%`,
  }
})

const footnote = computed(() => {
  if (!props.target) return ''
  if (props.target.kind === 'cpu') {
    return '* CPU 为瞬时多核核心负载占用率'
  }
  if (props.target.kind === 'memory') {
    return '* 内存为物理常驻内存总量 (RSS)'
  }
  return '* 显存包含 PyTorch/CUDA 上下文与缓存分配'
})
</script>

<template>
  <Teleport to="body">
    <div
      v-if="target"
      class="user-usage-popup"
      :class="{ 'is-pinned': isPinned }"
      :style="{ left: coords.x + 'px', top: coords.y + 'px' }"
      @mouseenter="emit('mouseenter')"
      @mouseleave="emit('mouseleave')"
    >
      <header class="user-popup-header">
        <div class="user-popup-title-area">
          <span class="user-popup-title" :title="title">{{ title }}</span>
          <span class="user-popup-mode-badge" :class="{ pinned: isPinned }">
            {{ isPinned ? '● 已固定' : '预览' }}
          </span>
        </div>
        <button
          type="button"
          class="user-popup-close-btn"
          title="关闭 / 取消固定"
          @click="emit('close')"
        >
          ×
        </button>
      </header>

      <div class="user-popup-status-bar">
        <span class="user-popup-status" :class="'status-' + status">
          {{ statusLabel }}
        </span>
        <span class="user-popup-count">{{ userRows.length }} 位用户活跃</span>
      </div>

      <div class="user-popup-content">
        <div v-if="userRows.length === 0" class="user-popup-empty">
          暂无用户活跃进程
        </div>

        <div v-else class="user-rows-list">
          <div
            v-for="row in visibleRows"
            :key="row.key"
            class="user-usage-row"
          >
            <span class="user-name" :title="row.name">{{ row.name }}</span>
            <span class="user-value">{{ row.displayValue }}</span>
          </div>

          <button
            v-if="userRows.length > 8"
            type="button"
            class="user-expand-toggle"
            @click="emit('toggleExpand')"
          >
            {{ expanded ? '收起列表' : `+ 展开其它 ${userRows.length - 8} 位用户` }}
          </button>
        </div>

        <div v-if="systemRow" class="user-popup-divider" />

        <div v-if="systemRow" class="user-usage-row is-system">
          <span class="user-name">{{ systemRow.name }}</span>
          <span class="user-value">{{ systemRow.displayValue }}</span>
        </div>
      </div>

      <footer class="user-popup-footer">
        {{ footnote }}
      </footer>
    </div>
  </Teleport>
</template>
