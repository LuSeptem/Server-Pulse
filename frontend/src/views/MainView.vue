<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { invoke } from '@tauri-apps/api/core'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useMonitorStore } from '../stores/monitor'
import { useEdgeDocking } from '../composables/useEdgeDocking'
import { useUserUsagePopup } from '../composables/useUserUsagePopup'
import ServerCard from '../components/ServerCard.vue'
import UserUsagePopup from '../components/UserUsagePopup.vue'

const store = useMonitorStore()
const showIntervalMenu = ref(false)
const presets = [1, 2, 3, 5, 10, 30, 60]

const {
  autoHideEnabled,
  dockSide,
  isHidden,
  toggleAutoHide,
} = useEdgeDocking()

const {
  currentTarget,
  isPinned,
  isExpanded,
  popupCoords,
  close: closePopup,
  toggleExpand: togglePopupExpand,
  onPopupMouseEnter,
  onPopupMouseLeave,
} = useUserUsagePopup()

const currentSnapshot = computed(() => {
  if (!currentTarget.value) return undefined
  return store.snapshots[currentTarget.value.serverId]
})

const currentDiskAttribution = computed(() => {
  const target = currentTarget.value
  if (!target || target.kind !== 'disk') return null
  return (
    store.diskAttribution.find(
      (r) => r.serverId === target.serverId && r.mount === target.mount,
    ) ?? null
  )
})

const startDragging = async (event: MouseEvent) => {
  if (event.button !== 0) return
  const target = event.target as HTMLElement | null
  if (!target) return
  if (target.closest('button, input, select, textarea, a, .card-actions, .cadence-dropdown, .no-drag')) {
    return
  }
  try {
    await invoke('drag_window')
  } catch {
    void getCurrentWindow().startDragging().catch(() => undefined)
  }
}

const selectInterval = async (val: number) => {
  showIntervalMenu.value = false
  await store.setIntervalSeconds(val)
}

// --- Disk scan trigger lifecycle -------------------------------------------
// One poll timer per server; each polls scan status every 5s until the remote
// scan reports inactive, then stops itself. Timers are cleared on unmount.
const scanPollTimers = new Map<string, ReturnType<typeof setInterval>>()
const scanErrors = ref<Record<string, string>>({})

function stopScanPolling(serverId: string) {
  const timer = scanPollTimers.get(serverId)
  if (timer !== undefined) {
    clearInterval(timer)
    scanPollTimers.delete(serverId)
  }
}

function startScanPolling(serverId: string) {
  stopScanPolling(serverId)
  const timer = setInterval(() => {
    void store
      .fetchDiskScanStatus(serverId)
      .then((status) => {
        if (!status.active) {
          stopScanPolling(serverId)
          // Fresh scan results are now merged on the backend; pick them up
          // immediately instead of waiting for the 5-minute interval.
          void store.refreshDiskAttribution().catch(() => undefined)
        }
      })
      .catch(() => undefined)
  }, 5000)
  scanPollTimers.set(serverId, timer)
}

async function handleScan(serverId: string) {
  try {
    const result = await store.triggerDiskScan(serverId)
    if (result.status === 'failed') {
      scanErrors.value = { ...scanErrors.value, [serverId]: result.detail || 'scan failed' }
      return
    }
    // Successful trigger clears any previous failure and starts polling.
    const nextErrors = { ...scanErrors.value }
    delete nextErrors[serverId]
    scanErrors.value = nextErrors
    await store.fetchDiskScanStatus(serverId).catch(() => undefined)
    startScanPolling(serverId)
  } catch (error) {
    scanErrors.value = {
      ...scanErrors.value,
      [serverId]: error instanceof Error ? error.message : String(error),
    }
  }
}

onUnmounted(() => {
  for (const serverId of [...scanPollTimers.keys()]) {
    stopScanPolling(serverId)
  }
})
</script>

<template>
  <section
    class="widget-window"
    :class="{
      'is-docked': dockSide !== 'none',
      'is-hidden': isHidden,
      ['dock-' + dockSide]: dockSide !== 'none'
    }"
    @mousedown="startDragging"
    @click="showIntervalMenu = false"
  >
    <!-- Visual edge dock indicator handle bar -->
    <div
      v-if="dockSide !== 'none'"
      class="edge-dock-indicator"
      :class="[dockSide, { 'is-hidden': isHidden }]"
    >
      <div class="edge-dock-grip" />
    </div>

    <header class="window-header drag-region" data-tauri-drag-region @mousedown="startDragging">
      <div data-tauri-drag-region>
        <span class="eyebrow" data-tauri-drag-region>SERVER PULSE</span>
        <h1 data-tauri-drag-region>Server monitor</h1>
      </div>
      <div class="header-actions no-drag">
        <button
          class="edge-btn"
          :class="{ active: autoHideEnabled }"
          :title="autoHideEnabled ? '贴边自动隐藏：已开启 (点击关闭) / Edge auto-hide: Enabled' : '贴边自动隐藏：已关闭 (点击开启) / Edge auto-hide: Disabled'"
          aria-label="Toggle edge auto-hide"
          @click="toggleAutoHide"
        >
          <svg
            class="edge-btn-icon"
            viewBox="0 0 20 20"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <rect
              x="1.5"
              y="2.5"
              width="17"
              height="15"
              rx="2.5"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-opacity="0.85"
            />
            <path
              d="M14.5 3V17"
              stroke="currentColor"
              stroke-width="2.5"
              stroke-linecap="round"
            />
            <path
              d="M4.5 10H11.5M11.5 10L8.5 7M11.5 10L8.5 13"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            />
          </svg>
        </button>
        <button title="History" @click="store.openWindow('history')">History</button>
        <button title="Manage" @click="store.openWindow('manage')">Manage</button>
        <button title="Hide" @click="store.hideMain()">—</button>
        <button title="Close" aria-label="Close" @click="store.closeMain()">×</button>
      </div>
    </header>

    <div class="summary-row drag-region" data-tauri-drag-region @mousedown="startDragging">
      <div class="summary-left" data-tauri-drag-region>
        <span data-tauri-drag-region>{{ store.onlineCount }}/{{ store.monitoredServers.length }} online</span>
        <div class="cadence-container" @click.stop>
          <button
            class="cadence-tag"
            :class="{ active: showIntervalMenu }"
            title="Click to directly change monitoring interval"
            @click="showIntervalMenu = !showIntervalMenu"
          >
            <svg
              class="cadence-icon"
              viewBox="0 0 16 16"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
            >
              <path
                d="M13.5 2.5v3.5h-3.5"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <path
                d="M2.5 13.5v-3.5h3.5"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <path
                d="M13.2 6.5A6 6 0 0 0 3.8 4.2L2.5 6"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
              <path
                d="M2.8 9.5a6 6 0 0 0 9.4 2.3l1.3-1.8"
                stroke="currentColor"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              />
            </svg>
            <span>{{ store.intervalSeconds }}s</span>
            <span class="caret">▾</span>
          </button>

          <div v-if="showIntervalMenu" class="cadence-dropdown">
            <div class="cadence-dropdown-title">Cadence / 刷新间隔</div>
            <div class="cadence-options">
              <button
                v-for="p in presets"
                :key="p"
                type="button"
                class="cadence-option"
                :class="{ active: store.intervalSeconds === p }"
                @click="selectInterval(p)"
              >
                {{ p }}s{{ p === 5 ? ' (Default)' : '' }}
              </button>
            </div>
          </div>
        </div>
      </div>
      <span class="muted data-root-label" :title="store.dataRoot">{{ store.dataRoot }}</span>
    </div>

    <section class="server-list">
      <ServerCard
        v-for="server in store.monitoredServers"
        :key="server.id"
        :server="server"
        :snapshot="store.snapshots[server.id]"
        :status="store.statuses[server.id] ?? 'stopped'"
        :error="store.errors[server.id]"
        :disk-attribution="store.diskAttribution.filter((r) => r.serverId === server.id)"
        :disk-scan-status="store.diskScans[server.id]"
        :scan-error="scanErrors[server.id] ?? null"
        @start="store.start(server)"
        @stop="store.stop(server.id)"
        @recheck="store.recheck(server)"
        @scan="handleScan(server.id)"
      />
      <div v-if="store.monitoredServers.length === 0" class="empty-state">
        <p v-if="store.servers.length === 0">No configured SSH servers.</p>
        <p v-else>No servers selected for monitoring.</p>
        <button @click="store.openWindow('manage')">Open Manage</button>
      </div>
    </section>

    <!-- User Resource Usage Breakdown Popup -->
    <UserUsagePopup
      :target="currentTarget"
      :snapshot="currentSnapshot"
      :is-pinned="isPinned"
      :expanded="isExpanded"
      :coords="popupCoords"
      :disk-attribution="currentDiskAttribution"
      @close="closePopup(true)"
      @toggle-expand="togglePopupExpand"
      @mouseenter="onPopupMouseEnter"
      @mouseleave="onPopupMouseLeave"
    />
  </section>
</template>
