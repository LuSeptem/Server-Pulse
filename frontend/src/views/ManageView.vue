<script setup lang="ts">
import { getCurrentWindow } from '@tauri-apps/api/window'
import { onMounted, reactive, ref } from 'vue'
import { useMonitorStore } from '../stores/monitor'
import type { AgentMergeResult, AgentServerState, ServerConfig } from '../types'

const store = useMonitorStore()

onMounted(async () => {
  if (!store.initialized) {
    await store.init()
  } else {
    await store.refreshSshConfig()
  }
  await store.fetchAgentStates()
  // Asynchronously check all agent statuses on mount
  void store.checkAllAgentStatuses()
})

const showForm = ref(false)
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

// Modals state
const configModalServer = ref<ServerConfig | null>(null)
const configInterval = ref(5)
const configRetention = ref(30)
const configLoading = ref(false)
const configError = ref('')

const syncModalServer = ref<ServerConfig | null>(null)
const syncCleanRemote = ref(false)
const syncLoading = ref(false)
const syncResult = ref<AgentMergeResult | null>(null)
const syncError = ref('')

const showSyncAllModal = ref(false)
const syncAllCleanRemote = ref(false)
const syncAllLoading = ref(false)
const syncAllResults = ref<Record<string, AgentMergeResult> | null>(null)
const syncAllError = ref('')

const uninstallModalServer = ref<ServerConfig | null>(null)
const uninstallLoading = ref(false)

const closeWindow = () => { void getCurrentWindow().close() }

function toggleForm() {
  if (showForm.value) resetForm()
  showForm.value = !showForm.value
}

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

async function cancelHostKeyAction() {
  const pending = store.pendingHostKeyAction
  const serverId = pending?.kind === 'start' ? pending.server.id : pending?.request.server.id
  if (serverId) {
    await store.clearSessionCredential(serverId).catch(() => undefined)
  }
  store.hostKeyChallenge = null
  store.pendingHostKeyAction = null
}

async function acceptHostKey() {
  try {
    const result = await store.acceptHostKey()
    const start = result && 'start' in result ? result.start : result
    if (start && start.status === 'started') {
      savedNotice.value = 'Host key verified; monitoring started.'
    } else if (start && start.status === 'verified') {
      savedNotice.value = 'Host key verified and server saved.'
      resetForm()
    }
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function forgetHostKey() {
  const pending = store.pendingHostKeyAction
  const server = pending
    ? (pending.kind === 'start' ? pending.server : pending.request.server)
    : store.servers.find((candidate) => candidate.host === store.hostKeyChallenge?.server)
  if (!server) return
  try {
    await store.forgetHostKey(server)
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

function fillFormWithCandidate(candidate: ServerConfig) {
  form.label = candidate.label
  form.host = candidate.host
  form.user = candidate.user ?? ''
  form.port = candidate.port ? String(candidate.port) : ''
  form.monitored = true
  form.passwordless = candidate.passwordless
  form.password = ''
  form.savePassword = false
  formError.value = ''
  showForm.value = true
}

async function importCandidate(candidate: ServerConfig) {
  formError.value = ''
  savedNotice.value = ''
  try {
    await store.importCandidate(candidate, true)
    savedNotice.value = `Imported ${candidate.label} and started monitoring.`
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function importAllCandidates() {
  formError.value = ''
  savedNotice.value = ''
  const count = store.unaddedCandidates.length
  try {
    await store.importAllCandidates(true)
    savedNotice.value = `Imported ${count} candidate(s) from SSH config.`
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function submit() {
  formError.value = ''
  savedNotice.value = ''
  const host = form.host.trim()
  const label = form.label.trim() || host
  if (!host) {
    formError.value = 'SSH alias, hostname, or IP address is required.'
    return
  }
  const port = form.port.trim() ? Number.parseInt(form.port.trim(), 10) : null
  if (port !== null && (!Number.isInteger(port) || port < 1 || port > 65535)) {
    formError.value = 'Port must be between 1 and 65535.'
    return
  }
  if (!form.passwordless && !form.password) {
    formError.value = 'Enter a password, or choose passwordless SSH.'
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
  const password = form.password
  const savePassword = form.savePassword
  // The input is cleared before IPC returns. The store keeps only the
  // in-memory retry request needed for host-key confirmation.
  form.password = ''
  form.savePassword = false
  try {
    const result = await store.saveServer(server, password, savePassword)
    if (result.start.status === 'host-key-required' || result.start.status === 'host-key-changed') {
      savedNotice.value = result.start.status === 'host-key-changed'
        ? 'Host key changed; verify the new fingerprint before continuing.'
        : 'Verify the host fingerprint before continuing.'
    } else if (result.start.status === 'password-required') {
      formError.value = result.start.detail ?? 'A password is required for this server.'
    } else {
      savedNotice.value = `${label} saved.`
      resetForm()
    }
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function reloadServers() {
  formError.value = ''
  try {
    await store.reloadServers()
    await store.fetchAgentStates()
    void store.checkAllAgentStatuses()
    savedNotice.value = `Reloaded ${store.servers.length} server(s) and ${store.sshConfigAliases.length} SSH alias(es).`
  } catch (error) {
    formError.value = error instanceof Error ? error.message : String(error)
  }
}

async function toggleMonitored(server: ServerConfig) {
  formError.value = ''
  try {
    await store.toggleServerMonitored(server)
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

// Agent Actions
function getAgentState(serverId: string): AgentServerState | undefined {
  return store.agentStates[serverId]
}

function getAgentStatusLabel(serverId: string): string {
  if (store.agentLoading[serverId]) return '检测中...'
  const state = store.agentStates[serverId]
  if (!state || state.lastStatus === 'unknown') return '状态未知'
  switch (state.lastStatus) {
    case 'running':
      return '运行中'
    case 'stale':
      return '心跳异常'
    case 'stopped':
      return '已停止'
    case 'not_installed':
      return '未部署'
    default:
      return '未知'
  }
}

function getAgentDotClass(serverId: string): string {
  if (store.agentLoading[serverId]) return 'dot-checking'
  const state = store.agentStates[serverId]
  return 'dot-' + (state?.lastStatus ?? 'unknown')
}

function getAgentLabelClass(serverId: string): string {
  if (store.agentLoading[serverId]) return 'label-checking'
  const state = store.agentStates[serverId]
  return 'label-' + (state?.lastStatus ?? 'unknown')
}

async function handleCheckAgent(server: ServerConfig) {
  try {
    await store.checkAgentStatus(server.id)
  } catch (err) {
    formError.value = String(err)
  }
}

async function handleCheckAllAgents() {
  try {
    await store.checkAllAgentStatuses()
  } catch (err) {
    formError.value = String(err)
  }
}

async function handleDeployAndStart(server: ServerConfig) {
  const existing = store.agentStates[server.id]
  const interval = existing?.intervalSeconds ?? 5
  const retention = existing?.retentionDays ?? 30
  try {
    await store.deployAndStartAgent(server.id, interval, retention)
  } catch (err) {
    window.alert(`部署/启动失败: ${String(err)}`)
  }
}

async function handleStopAgent(server: ServerConfig) {
  try {
    await store.stopAgent(server.id)
  } catch (err) {
    window.alert(`停止失败: ${String(err)}`)
  }
}

async function handleRestartAgent(server: ServerConfig) {
  try {
    await store.restartAgent(server.id)
  } catch (err) {
    window.alert(`重启失败: ${String(err)}`)
  }
}

// Config Modal
function openConfigModal(server: ServerConfig) {
  configModalServer.value = server
  const existing = store.agentStates[server.id]
  configInterval.value = existing?.intervalSeconds ?? 5
  configRetention.value = existing?.retentionDays ?? 30
  configError.value = ''
}

function closeConfigModal() {
  configModalServer.value = null
  configError.value = ''
}

async function handleSaveConfig() {
  if (!configModalServer.value) return
  if (configInterval.value < 1 || configInterval.value > 3600) {
    configError.value = '采样间隔必须在 1 到 3600 秒之间'
    return
  }
  if (configRetention.value < 1 || configRetention.value > 3650) {
    configError.value = '保留天数必须在 1 到 3650 天之间'
    return
  }
  configLoading.value = true
  try {
    await store.updateAgentConfig(
      configModalServer.value.id,
      configInterval.value,
      configRetention.value,
    )
    closeConfigModal()
  } catch (err) {
    configError.value = String(err)
  } finally {
    configLoading.value = false
  }
}

// Sync Modal
function openSyncModal(server: ServerConfig) {
  syncModalServer.value = server
  syncCleanRemote.value = false
  syncResult.value = null
  syncError.value = ''
}

function closeSyncModal() {
  syncModalServer.value = null
  syncResult.value = null
  syncError.value = ''
}

async function handleExecuteSync() {
  if (!syncModalServer.value) return
  syncLoading.value = true
  syncError.value = ''
  syncResult.value = null
  try {
    const res = await store.pullAndMergeRecords(syncModalServer.value.id, syncCleanRemote.value)
    syncResult.value = res
  } catch (err) {
    syncError.value = String(err)
  } finally {
    syncLoading.value = false
  }
}

// Sync All Modal
function openSyncAllModal() {
  showSyncAllModal.value = true
  syncAllCleanRemote.value = false
  syncAllResults.value = null
  syncAllError.value = ''
}

function closeSyncAllModal() {
  showSyncAllModal.value = false
  syncAllResults.value = null
  syncAllError.value = ''
}

async function handleExecuteSyncAll() {
  syncAllLoading.value = true
  syncAllError.value = ''
  syncAllResults.value = null
  try {
    const res = await store.pullAndMergeAllRecords(syncAllCleanRemote.value)
    syncAllResults.value = res
  } catch (err) {
    syncAllError.value = String(err)
  } finally {
    syncAllLoading.value = false
  }
}

// Uninstall Modal
function openUninstallModal(server: ServerConfig) {
  uninstallModalServer.value = server
}

function closeUninstallModal() {
  uninstallModalServer.value = null
}

async function handleExecuteUninstall() {
  if (!uninstallModalServer.value) return
  uninstallLoading.value = true
  try {
    await store.uninstallAgent(uninstallModalServer.value.id)
    closeUninstallModal()
  } catch (err) {
    window.alert(`卸载失败: ${String(err)}`)
  } finally {
    uninstallLoading.value = false
  }
}
</script>

<template>
  <section class="page-window">
    <header class="page-header">
      <div>
        <span class="eyebrow">SERVER PULSE</span>
        <h1>SSH servers & Agent</h1>
      </div>
      <div class="page-actions">
        <button title="刷新所有 Agent 状态" @click="handleCheckAllAgents">
          <span v-if="store.agentGlobalLoading">刷新中...</span>
          <span v-else>刷新 Agent</span>
        </button>
        <button class="primary-button" title="一键同步所有服务器历史记录" @click="openSyncAllModal">
          一键同步所有
        </button>
        <button title="Reload SSH config" @click="reloadServers">Reload SSH</button>
        <button class="primary-button" @click="toggleForm">{{ showForm ? 'Cancel' : '+ Add server' }}</button>
        <button @click="closeWindow">Close</button>
      </div>
    </header>

    <div class="info-card">
      <div class="ssh-config-info">
        <div><strong>SSH config:</strong> {{ store.sshConfigPath || 'not found' }}</div>
        <div v-if="store.sshConfigAliases.length">
          <span>Detected aliases (click to fill):</span>
          <div>
            <button
              v-for="alias in store.sshConfigAliases"
              :key="alias"
              class="alias-badge"
              type="button"
              :title="'Click to populate ' + alias"
              @click="fillFormWithCandidate(store.sshConfigCandidates.find(c => c.host === alias) ?? { id: alias, label: alias, host: alias, monitored: true, passwordless: true })"
            >
              {{ alias }}
            </button>
          </div>
        </div>
        <div v-else-if="store.sshConfigError" class="error-text">Read error: {{ store.sshConfigError }}</div>
        <div v-else class="muted">No concrete Host aliases detected.</div>
      </div>
    </div>

    <!-- Candidate discovery section -->
    <section v-if="store.unaddedCandidates.length" class="candidate-section">
      <div class="candidate-header">
        <strong>Discovered from SSH config ({{ store.unaddedCandidates.length }} available)</strong>
        <button class="primary-button" type="button" @click="importAllCandidates">Import all ({{ store.unaddedCandidates.length }})</button>
      </div>
      <div class="candidate-list">
        <div v-for="candidate in store.unaddedCandidates" :key="candidate.id" class="candidate-item">
          <div>
            <strong>{{ candidate.label }}</strong>
            <span class="muted"> · {{ candidate.host }}<template v-if="candidate.user"> · {{ candidate.user }}</template><template v-if="candidate.port"> :{{ candidate.port }}</template></span>
          </div>
          <div class="candidate-actions">
            <button class="primary-button" type="button" @click="importCandidate(candidate)">+ Add to monitor</button>
            <button type="button" @click="fillFormWithCandidate(candidate)">Edit</button>
          </div>
        </div>
      </div>
    </section>

    <!-- Add Server Form -->
    <form v-if="showForm" class="editor-card" @submit.prevent="submit">
      <h2>Add SSH server</h2>
      <div class="form-grid">
        <label class="field">
          <span>Display name</span>
          <input v-model="form.label" placeholder="RTX 3090" autocomplete="off" />
        </label>
        <label class="field">
          <span>SSH alias / Hostname / IP</span>
          <input v-model="form.host" placeholder="123.23.23.23 / gpu-01" autocomplete="off" required />
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
        <span>Start live monitoring after saving</span>
      </label>
      <label class="check-row">
        <input v-model="form.passwordless" type="checkbox" />
        <span>Passwordless SSH (use key or ssh-agent)</span>
      </label>
      <template v-if="!form.passwordless">
        <label class="field password-field">
          <span>Password (used for this run; optionally save it in the OS credential store)</span>
          <input v-model="form.password" type="password" autocomplete="new-password" />
        </label>
        <label class="check-row" :class="{ disabled: !form.password }">
          <input v-model="form.savePassword" type="checkbox" :disabled="!form.password" />
          <span>Save password in the OS credential store</span>
        </label>
      </template>
      <p v-if="formError" class="error-text">{{ formError }}</p>
      <p v-if="savedNotice" class="success-text">{{ savedNotice }}</p>
      <div class="card-actions">
        <button type="submit">Save server</button>
      </div>
    </form>

    <!-- Host key confirmation -->
    <div v-if="store.hostKeyChallenge" class="modal-backdrop" @click.self="cancelHostKeyAction">
      <div class="modal-card host-key-modal">
        <div class="modal-header">
          <h3>{{ store.hostKeyChallenge.state === 'changed' ? 'Host key changed' : 'Verify host fingerprint' }}</h3>
          <button class="modal-close-btn" type="button" @click="cancelHostKeyAction">✕</button>
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
        </div>
        <div class="modal-footer">
          <button type="button" @click="cancelHostKeyAction">Cancel</button>
          <button
            v-if="store.hostKeyChallenge.state === 'changed'"
            type="button"
            @click="forgetHostKey"
          >
            Forget application key and reverify
          </button>
          <button
            v-else
            class="primary-button"
            type="button"
            @click="acceptHostKey"
          >
            Verify and apply
          </button>
        </div>
      </div>
    </div>

    <!-- Server List with Agent Management -->
    <div v-if="store.servers.length" class="manage-list">
      <article v-for="server in store.servers" :key="server.id" class="manage-card">
        <!-- Top row: Server basic info & direct monitor -->
        <div class="manage-top-row">
          <div class="manage-main">
            <label class="monitor-checkbox" :title="server.monitored ? '实时轮询中 (点击暂停)' : '实时轮询已暂停 (点击开启)'">
              <input
                type="checkbox"
                :checked="server.monitored"
                @change="toggleMonitored(server)"
              />
            </label>
            <div class="server-meta">
              <div class="server-name-row">
                <strong>{{ server.label }}</strong>
                <span class="auth-badge">{{ server.passwordless ? 'Passwordless' : 'Keyring' }}</span>
              </div>
              <span class="server-endpoint">{{ server.host }} · {{ server.user ?? 'SSH config' }}<template v-if="server.port">:{{ server.port }}</template></span>
            </div>
          </div>
          <div class="manage-actions">
            <span class="status-pill" :class="'status-' + (store.statuses[server.id] ?? 'stopped').split(':')[0]" :title="'实时监控状态: ' + (store.statuses[server.id] ?? 'stopped')">
              {{ store.statuses[server.id] ?? 'stopped' }}
            </span>
            <button class="ghost-danger-btn" title="Remove server" @click="remove(server)">Remove</button>
          </div>
        </div>

        <!-- Bottom row: Persistent Agent Management -->
        <div class="agent-tier">
          <div class="agent-summary">
            <span class="agent-dot" :class="getAgentDotClass(server.id)"></span>
            <span class="agent-name">常驻监控</span>
            <span class="agent-status-label" :class="getAgentLabelClass(server.id)">
              {{ getAgentStatusLabel(server.id) }}
            </span>
            <span v-if="getAgentState(server.id)" class="agent-metrics-meta">
              · {{ getAgentState(server.id)?.intervalSeconds ?? 5 }}s 采样 / {{ getAgentState(server.id)?.retentionDays ?? 30 }}天保留
              <template v-if="getAgentState(server.id)?.lastMergeAt">
                · {{ getAgentState(server.id)?.mergeCursorUtc ? '游标 ' + getAgentState(server.id)?.mergeCursorUtc : '已同步' }}
              </template>
            </span>
            <span v-if="getAgentState(server.id)?.lastError" class="agent-err-badge" :title="getAgentState(server.id)?.lastError">
              ! 异常
            </span>
          </div>

          <div class="agent-controls">
            <button
              class="agent-control-btn"
              title="检测该服务器 Agent 状态"
              :disabled="store.agentLoading[server.id]"
              @click="handleCheckAgent(server)"
            >
              检测
            </button>
            <button
              class="agent-control-btn"
              title="设置采样间隔与保留天数"
              @click="openConfigModal(server)"
            >
              设置
            </button>
            <template v-if="getAgentState(server.id)?.lastStatus === 'running' || getAgentState(server.id)?.lastStatus === 'stale'">
              <button
                class="agent-control-btn"
                title="重启常驻监控进程"
                :disabled="store.agentLoading[server.id]"
                @click="handleRestartAgent(server)"
              >
                重启
              </button>
              <button
                class="agent-control-btn"
                title="停止常驻监控进程"
                :disabled="store.agentLoading[server.id]"
                @click="handleStopAgent(server)"
              >
                停止
              </button>
              <button
                class="agent-control-btn sync-btn"
                title="拉取服务器常驻监控记录并合并到本地历史"
                :disabled="store.agentLoading[server.id]"
                @click="openSyncModal(server)"
              >
                同步
              </button>
            </template>
            <template v-else>
              <button
                class="agent-control-btn deploy-btn"
                title="部署并在服务器后台启动常驻监控"
                :disabled="store.agentLoading[server.id]"
                @click="handleDeployAndStart(server)"
              >
                部署启动
              </button>
              <button
                class="agent-control-btn sync-btn"
                title="同步已有历史数据"
                :disabled="store.agentLoading[server.id]"
                @click="openSyncModal(server)"
              >
                同步
              </button>
            </template>
            <button
              v-if="getAgentState(server.id)?.lastStatus !== 'not_installed'"
              class="agent-control-btn uninstall-btn"
              title="卸载服务器上的常驻监控并删除~/.serverpulse目录"
              @click="openUninstallModal(server)"
            >
              卸载
            </button>
          </div>
        </div>
      </article>
    </div>
    <div v-else class="empty-state">
      <p>No configured SSH servers.</p>
    </div>

    <!-- Agent Config Modal -->
    <div v-if="configModalServer" class="modal-backdrop" @click.self="closeConfigModal">
      <div class="modal-card">
        <div class="modal-header">
          <h3>常驻监控参数设置 - {{ configModalServer.label }}</h3>
          <button class="modal-close-btn" @click="closeConfigModal">✕</button>
        </div>
        <div class="modal-body">
          <label class="field">
            <span>采样间隔（秒）(推荐 5 秒，范围 1 - 3600)</span>
            <input v-model.number="configInterval" type="number" min="1" max="3600" />
          </label>
          <label class="field">
            <span>历史记录保留天数（天）(默认 30 天，范围 1 - 3650)</span>
            <input v-model.number="configRetention" type="number" min="1" max="3650" />
          </label>
          <p class="modal-hint">
            💡 保存后将更新远端 <code>~/.serverpulse/config</code> 文件，并在下一次采样周期自动生效。
          </p>
          <p v-if="configError" class="error-text">{{ configError }}</p>
        </div>
        <div class="modal-footer">
          <button @click="closeConfigModal">取消</button>
          <button class="primary-button" :disabled="configLoading" @click="handleSaveConfig">
            {{ configLoading ? '保存中...' : '保存配置' }}
          </button>
        </div>
      </div>
    </div>

    <!-- Agent Sync Single Modal -->
    <div v-if="syncModalServer" class="modal-backdrop" @click.self="closeSyncModal">
      <div class="modal-card">
        <div class="modal-header">
          <h3>同步监控历史记录 - {{ syncModalServer.label }}</h3>
          <button class="modal-close-btn" @click="closeSyncModal">✕</button>
        </div>
        <div class="modal-body">
          <p>
            将从服务器 <strong>{{ syncModalServer.host }}</strong> 拉取常驻 Agent 记录的分钟级指标数据，并合并到本地历史归档库中。
          </p>
          <div class="modal-result-box">
            <div><strong>服务器:</strong> {{ syncModalServer.label }} ({{ syncModalServer.host }})</div>
            <div>
              <strong>上次同步游标:</strong>
              {{ getAgentState(syncModalServer.id)?.mergeCursorUtc ? getAgentState(syncModalServer.id)?.mergeCursorUtc + ' (UTC)' : '首次同步 (拉取所有历史)' }}
            </div>
            <div v-if="getAgentState(syncModalServer.id)?.lastMergeSummary">
              <strong>上次同步结果:</strong> {{ getAgentState(syncModalServer.id)?.lastMergeSummary }}
            </div>
          </div>

          <label class="check-row">
            <input v-model="syncCleanRemote" type="checkbox" />
            <span>同步后清理远端已合并记录以节省服务器磁盘空间（默认关闭）</span>
          </label>

          <div v-if="syncResult" class="modal-result-box">
            <strong style="color: #85e89d;">✅ 同步完成</strong>
            <div>拉取行数: {{ syncResult.pulledLines }} 行 ({{ syncResult.recordFiles }} 个历史文件)</div>
            <div>新增历史分钟数: {{ syncResult.addedMinutes }} 分钟</div>
            <div>更新/合并记录数: {{ syncResult.updatedServers }} 条</div>
            <div v-if="syncResult.cursorUtc">最新同步游标: {{ syncResult.cursorUtc }} UTC</div>
          </div>

          <p v-if="syncError" class="error-text">❌ 同步失败: {{ syncError }}</p>
        </div>
        <div class="modal-footer">
          <button @click="closeSyncModal">{{ syncResult ? '完成' : '取消' }}</button>
          <button
            class="primary-button"
            :disabled="syncLoading"
            @click="handleExecuteSync"
          >
            {{ syncLoading ? '同步中...' : (syncResult ? '再次同步' : '开始同步') }}
          </button>
        </div>
      </div>
    </div>

    <!-- Agent Sync All Modal -->
    <div v-if="showSyncAllModal" class="modal-backdrop" @click.self="closeSyncAllModal">
      <div class="modal-card">
        <div class="modal-header">
          <h3>一键同步所有服务器历史记录</h3>
          <button class="modal-close-btn" @click="closeSyncAllModal">✕</button>
        </div>
        <div class="modal-body">
          <p>
            将并发/顺序拉取所有配置的 <strong>{{ store.servers.length }}</strong> 台服务器上的常驻 Agent 历史记录，并合并到本地数据库中。
          </p>

          <label class="check-row">
            <input v-model="syncAllCleanRemote" type="checkbox" />
            <span>同步后清理远端已合并记录以节省服务器磁盘空间（默认关闭）</span>
          </label>

          <div v-if="syncAllResults" class="sync-server-list">
            <div
              v-for="server in store.servers"
              :key="server.id"
              class="sync-server-row"
            >
              <div>
                <strong>{{ server.label }}</strong>
                <span class="muted"> ({{ server.host }})</span>
              </div>
              <div>
                <template v-if="syncAllResults[server.id]?.status === 'ok'">
                  <span style="color: #85e89d;">
                    +{{ syncAllResults[server.id].addedMinutes }}分 (拉取{{ syncAllResults[server.id].pulledLines }}行)
                  </span>
                </template>
                <template v-else-if="syncAllResults[server.id]?.status === 'error'">
                  <span style="color: #ffa198;" :title="syncAllResults[server.id]?.error ?? ''">
                    ⚠️ 失败
                  </span>
                </template>
                <template v-else>
                  <span class="muted">-</span>
                </template>
              </div>
            </div>
          </div>

          <p v-if="syncAllError" class="error-text">❌ 同步出现错误: {{ syncAllError }}</p>
        </div>
        <div class="modal-footer">
          <button @click="closeSyncAllModal">{{ syncAllResults ? '完成' : '取消' }}</button>
          <button
            class="primary-button"
            :disabled="syncAllLoading"
            @click="handleExecuteSyncAll"
          >
            {{ syncAllLoading ? '正在同步所有服务器...' : (syncAllResults ? '再次同步' : '开始全部同步') }}
          </button>
        </div>
      </div>
    </div>

    <!-- Uninstall Confirmation Modal -->
    <div v-if="uninstallModalServer" class="modal-backdrop" @click.self="closeUninstallModal">
      <div class="modal-card">
        <div class="modal-header">
          <h3 style="color: #ffa198;">卸载常驻监控 - {{ uninstallModalServer.label }}</h3>
          <button class="modal-close-btn" @click="closeUninstallModal">✕</button>
        </div>
        <div class="modal-body">
          <p>
            确定要卸载服务器 <strong>{{ uninstallModalServer.label }} ({{ uninstallModalServer.host }})</strong> 上的常驻监控吗？
          </p>
          <p class="modal-hint" style="color: #ffa198;">
            ⚠️ 此操作将停止正在运行的 Agent 后台进程，并删除远端 <code>~/.serverpulse</code> 目录及所有历史数据文件。本地已同步的历史数据将保留。
          </p>
        </div>
        <div class="modal-footer">
          <button @click="closeUninstallModal">取消</button>
          <button
            class="danger-button"
            :disabled="uninstallLoading"
            @click="handleExecuteUninstall"
          >
            {{ uninstallLoading ? '正在卸载...' : '确认卸载' }}
          </button>
        </div>
      </div>
    </div>
  </section>
</template>

