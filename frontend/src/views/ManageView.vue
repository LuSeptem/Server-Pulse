<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import { reactive, ref } from 'vue'
import { useMonitorStore } from '../stores/monitor'
import type { ServerConfig } from '../types'

const store = useMonitorStore()
const showForm = ref(true)
const formError = ref('')
const savedNotice = ref('')
const form = reactive({
  label: '',
  host: '',
  user: '',
  port: '',
  monitored: true,
  passwordless: true,
  password: '',
  savePassword: false,
})

const closeWindow = () => { void getCurrentWindow().close() }

function resetForm() {
  form.label = ''
  form.host = ''
  form.user = ''
  form.port = ''
  form.monitored = true
  form.passwordless = true
  form.password = ''
  form.savePassword = false
  formError.value = ''
}

async function submit() {
  formError.value = ''
  savedNotice.value = ''
  const host = form.host.trim()
  const label = form.label.trim() || host
  if (!host) {
    formError.value = 'SSH alias or hostname is required.'
    return
  }
  const port = form.port.trim() ? Number.parseInt(form.port.trim(), 10) : null
  if (port !== null && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    formError.value = 'Port must be between 1 and 65535.'
    return
  }
  if (!form.passwordless && (!form.password || !form.savePassword)) {
    formError.value = 'Choose passwordless SSH or enter a password and save it in the OS credential store.'
    return
  }
  const server: ServerConfig = {
    id: `server-${Date.now()}`,
    label,
    host,
    user: form.user.trim() || null,
    port,
    monitored: form.monitored,
    passwordless: form.passwordless,
  }
  try {
    await store.saveServer(server, form.password, form.savePassword)
    savedNotice.value = `${label} saved.`
    resetForm()
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function reloadServers() {
  formError.value = ''
  try {
    await store.reloadServers()
    savedNotice.value = `Reloaded ${store.servers.length} server(s) and ${store.sshConfigAliases.length} SSH alias(es).`
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function remove(server: ServerConfig) {
  if (!window.confirm(`Remove ${server.label}?`)) return
  try {
    await store.deleteServer(server.id)
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}
</script>

<template>
  <section class="page-window">
    <header class="page-header">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>SSH servers</h1>
      </div>
      <div class="page-actions">
        <button title="Reload SSH config" @click="reloadServers">Reload</button>
        <button @click="showForm = !showForm">{{ showForm ? 'Cancel' : 'Add server' }}</button>
        <button @click="closeWindow">Close</button>
      </div>
    </header>

    <p class="muted">Existing OpenSSH aliases are detected from your user SSH config. Add a hostname or alias here to save it to Server Pulse.</p>
    <p class="ssh-config-info">
      <span>SSH config: {{ store.sshConfigPath || 'not found' }}</span>
      <span v-if="store.sshConfigAliases.length">Detected aliases: {{ store.sshConfigAliases.join(', ') }}</span>
      <span v-else-if="store.sshConfigError" class="error-text">Read error: {{ store.sshConfigError }}</span>
      <span v-else>No concrete Host aliases detected.</span>
    </p>

    <form v-if="showForm" class="editor-card" @submit.prevent="submit">
      <h2>Add SSH server</h2>
      <div class="form-grid">
        <label class="field">
          <span>Display name</span>
          <input v-model="form.label" placeholder="RTX 3090" autocomplete="off" />
        </label>
        <label class="field">
          <span>SSH alias / hostname</span>
          <input v-model="form.host" placeholder="gpu-01" autocomplete="off" required />
        </label>
        <label class="field">
          <span>User (optional)</span>
          <input v-model="form.user" placeholder="Uses SSH config" autocomplete="username" />
        </label>
        <label class="field">
          <span>Port (optional)</span>
          <input v-model="form.port" type="number" min="1" max="65535" placeholder="22" inputmode="numeric" />
        </label>
      </div>
      <label class="check-row">
        <input v-model="form.monitored" type="checkbox" />
        <span>Start monitoring after saving</span>
      </label>
      <label class="check-row">
        <input v-model="form.passwordless" type="checkbox" />
        <span>Passwordless SSH (use key or ssh-agent)</span>
      </label>
      <template v-if="!form.passwordless">
        <label class="field password-field">
          <span>Password (saved only in the OS credential store)</span>
          <input v-model="form.password" type="password" autocomplete="new-password" />
        </label>
        <label class="check-row" :class="{ disabled: !form.password }">
          <input v-model="form.savePassword" type="checkbox" :disabled="!form.password" />
          <span>Save password for this server</span>
        </label>
      </template>
      <p v-if="formError" class="error-text">{{ formError }}</p>
      <p v-if="savedNotice" class="success-text">{{ savedNotice }}</p>
      <div class="card-actions">
        <button type="submit">Save server</button>
      </div>
    </form>

    <div v-if="store.servers.length" class="manage-list">
      <article v-for="server in store.servers" :key="server.id" class="manage-row">
        <div>
          <strong>{{ server.label }}</strong>
          <span class="muted">{{ server.host }} · {{ server.user ?? 'SSH config user' }}<template v-if="server.port"> · {{ server.port }}</template></span>
        </div>
        <div class="manage-actions">
          <span class="auth-mode">{{ server.passwordless ? 'Passwordless' : 'Saved password' }}</span>
          <span class="status-pill" :class="'status-' + (store.statuses[server.id] ?? 'stopped').split(':')[0]">{{ store.statuses[server.id] ?? 'stopped' }}</span>
          <button class="danger-button" @click="remove(server)">Remove</button>
        </div>
      </article>
    </div>
    <div v-else class="empty-state">
      <p>No configured SSH servers.</p>
    </div>
  </section>
</template>
