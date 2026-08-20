<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useMonitorStore } from './stores/monitor'
import MainView from './views/MainView.vue'
import ManageView from './views/ManageView.vue'
import HistoryView from './views/HistoryView.vue'

const store = useMonitorStore()
const view = computed(() => new URLSearchParams(window.location.search).get('view') ?? 'main')
const hostKeyBusy = ref(false)
const hostKeyError = ref('')

const pendingHostKeyServer = computed(() => {
  const pending = store.pendingHostKeyAction
  if (pending?.kind === 'start') return pending.server
  if (pending?.kind === 'apply') return pending.request.server
  return store.servers.find((server) => server.host === store.hostKeyChallenge?.server)
})

async function cancelHostKeyAction() {
  const serverId = pendingHostKeyServer.value?.id
  if (serverId) await store.clearSessionCredential(serverId).catch(() => undefined)
  hostKeyError.value = ''
  store.hostKeyChallenge = null
  store.pendingHostKeyAction = null
}

async function acceptHostKey() {
  hostKeyBusy.value = true
  hostKeyError.value = ''
  try {
    await store.acceptHostKey()
  } catch (error) {
    hostKeyError.value = error instanceof Error ? error.message : String(error)
  } finally {
    hostKeyBusy.value = false
  }
}

async function forgetHostKey() {
  const server = pendingHostKeyServer.value
  if (!server) return
  hostKeyBusy.value = true
  hostKeyError.value = ''
  try {
    await store.forgetHostKey(server)
  } catch (error) {
    hostKeyError.value = error instanceof Error ? error.message : String(error)
  } finally {
    hostKeyBusy.value = false
  }
}

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

    <div
      v-if="view === 'main' && store.hostKeyChallenge"
      class="modal-backdrop"
      @click.self="cancelHostKeyAction"
    >
      <div class="modal-card host-key-modal">
        <div class="modal-header">
          <h3>{{ store.hostKeyChallenge.state === 'changed' ? 'Host key changed' : 'Verify host fingerprint' }}</h3>
          <button class="modal-close-btn" type="button" :disabled="hostKeyBusy" @click="cancelHostKeyAction">✕</button>
        </div>
        <div class="modal-body">
          <p>
            <strong>{{ store.hostKeyChallenge.server }}</strong>:{{ store.hostKeyChallenge.port }}
            {{ store.hostKeyChallenge.state === 'changed'
              ? 'no longer matches a previously trusted key. The connection is blocked until you forget the application key and verify again.'
              : 'is not yet trusted by Server Pulse.' }}
          </p>
          <div v-for="key in store.hostKeyChallenge.keys" :key="key.algorithm + key.fingerprint" class="host-key-row">
            <strong>{{ key.algorithm }}</strong>
            <code>{{ key.fingerprint }}</code>
          </div>
          <p class="modal-hint">
            The existing user <code>~/.ssh/known_hosts</code> is read-only. Server Pulse writes only its data-root <code>known_hosts</code> file.
          </p>
          <p v-if="hostKeyError" class="error-text">{{ hostKeyError }}</p>
        </div>
        <div class="modal-footer">
          <button type="button" :disabled="hostKeyBusy" @click="cancelHostKeyAction">Cancel</button>
          <button
            v-if="store.hostKeyChallenge.state === 'changed'"
            type="button"
            :disabled="hostKeyBusy"
            @click="forgetHostKey"
          >
            Forget application key and reverify
          </button>
          <button
            v-else
            class="primary-button"
            type="button"
            :disabled="hostKeyBusy"
            @click="acceptHostKey"
          >
            Verify and apply
          </button>
        </div>
      </div>
    </div>
  </main>
</template>
