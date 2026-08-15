<script setup lang="ts">
import { computed, onMounted } from 'vue'
import { useMonitorStore } from './stores/monitor'
import MainView from './views/MainView.vue'
import ManageView from './views/ManageView.vue'
import HistoryView from './views/HistoryView.vue'

const store = useMonitorStore()
const view = computed(() => new URLSearchParams(window.location.search).get('view') ?? 'main')

onMounted(() => store.init())
</script>

<template>
  <main class="app-shell">
    <MainView v-if="view === 'main'" />
    <ManageView v-else-if="view === 'manage'" />
    <HistoryView v-else-if="view === 'history'" />
    <section v-else class="empty-state">
      <h1>Server Pulse</h1>
      <p>Unknown window view: {{ view }}</p>
    </section>
  </main>
</template>
