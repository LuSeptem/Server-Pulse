<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import { useMonitorStore } from '../stores/monitor'

const store = useMonitorStore()
const closeWindow = () => { void getCurrentWindow().close() }
</script>

<template>
  <section class="page-window">
    <header class="page-header">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>SSH servers</h1>
      </div>
      <button @click="closeWindow">Close</button>
    </header>
    <p class="muted">The preview reads the repository seed configuration. Editing and credential verification are wired through the Rust command layer next.</p>
    <div class="manage-list">
      <article v-for="server in store.servers" :key="server.id" class="manage-row">
        <div>
          <strong>{{ server.label }}</strong>
          <span class="muted">{{ server.host }} · {{ server.user ?? 'SSH config user' }}</span>
        </div>
        <span class="status-pill" :class="'status-' + (store.statuses[server.id] ?? 'stopped').split(':')[0]">{{ store.statuses[server.id] ?? 'stopped' }}</span>
      </article>
    </div>
  </section>
</template>
