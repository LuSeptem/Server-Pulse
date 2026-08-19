<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
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
    />

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
            viewBox="0 0 16 16"
            fill="none"
            xmlns="http://www.w3.org/2000/svg"
          >
            <rect
              x="2"
              y="2.5"
              width="12"
              height="11"
              rx="2"
              stroke="currentColor"
              stroke-width="1.2"
              stroke-opacity="0.6"
            />
            <line
              x1="11.5"
              y1="3"
              x2="11.5"
              y2="13"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
            />
            <path
              d="M5 8H8.5M8.5 8L6.5 6M8.5 8L6.5 10"
              stroke="currentColor"
              stroke-width="1.3"
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
            ⚡ {{ store.intervalSeconds }}s <span class="caret">▾</span>
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
        @start="store.start(server)"
        @stop="store.stop(server.id)"
        @recheck="store.recheck(server)"
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
      @close="closePopup(true)"
      @toggle-expand="togglePopupExpand"
      @mouseenter="onPopupMouseEnter"
      @mouseleave="onPopupMouseLeave"
    />
  </section>
</template>
