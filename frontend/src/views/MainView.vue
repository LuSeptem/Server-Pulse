<script setup lang="ts">
import { useMonitorStore } from '../stores/monitor'
import ServerCard from '../components/ServerCard.vue'

const store = useMonitorStore()
</script>

<template>
  <section class="widget-window">
    <header class="window-header drag-region">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>Server monitor</h1>
      </div>
      <div class="header-actions no-drag">
        <button title="History" @click="store.openWindow('history')">History</button>
        <button title="Manage" @click="store.openWindow('manage')">Manage</button>
        <button title="Hide" @click="store.hideMain()">—</button>
      </div>
    </header>

    <div class="summary-row">
      <span>{{ store.onlineCount }}/{{ store.servers.length }} online</span>
      <span class="muted">{{ store.dataRoot }}</span>
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
