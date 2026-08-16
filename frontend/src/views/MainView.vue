<script setup lang="ts">
import { ref } from 'vue'
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useMonitorStore } from '../stores/monitor'
import ServerCard from '../components/ServerCard.vue'

const store = useMonitorStore()
const showIntervalMenu = ref(false)
const presets = [1, 2, 3, 5, 10, 30, 60]

const startDragging = (event: MouseEvent) => {
  if ((event.target as HTMLElement).closest('button, input, a, .cadence-dropdown')) return
  void getCurrentWindow().startDragging().catch(() => undefined)
}

const selectInterval = async (val: number) => {
  showIntervalMenu.value = false
  await store.setIntervalSeconds(val)
}
</script>

<template>
  <section class="widget-window" @click="showIntervalMenu = false">
    <header class="window-header drag-region" data-tauri-drag-region @mousedown="startDragging">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>Server monitor</h1>
      </div>
      <div class="header-actions no-drag">
        <button title="History" @click="store.openWindow('history')">History</button>
        <button title="Manage" @click="store.openWindow('manage')">Manage</button>
        <button title="Hide" @click="store.hideMain()">—</button>
        <button title="Close" aria-label="Close" @click="store.closeMain()">×</button>
      </div>
    </header>

    <div class="summary-row">
      <div class="summary-left">
        <span>{{ store.onlineCount }}/{{ store.servers.length }} online</span>
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
        v-for="server in store.servers"
        :key="server.id"
        :server="server"
        :snapshot="store.snapshots[server.id]"
        :status="store.statuses[server.id] ?? 'stopped'"
        :error="store.errors[server.id]"
        @start="store.start(server)"
        @stop="store.stop(server.id)"
        @recheck="store.recheck(server)"
      />
      <div v-if="store.servers.length === 0" class="empty-state">
        <p>No configured SSH servers.</p>
        <button @click="store.openWindow('manage')">Open Manage</button>
      </div>
    </section>
  </section>
</template>
