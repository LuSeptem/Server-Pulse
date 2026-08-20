import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { defineStore } from 'pinia'
import type {
  AgentMergeResult,
  AgentServerState,
  ApplyServerResult,
  HistoryEntry,
  HostKeyChallenge,
  MetricSnapshot,
  ServerConfig,
  SshConfigInfo,
  StartResult,
} from '../types'

interface SnapshotEvent {
  serverId: string
  timestamp: string
  sequence: number
  payload: MetricSnapshot
}

interface StatusEvent {
  serverId: string
  timestamp: string
  sequence: number
  payload: {
    status: string
    detail?: { code: string; messageKey: string; retryable: boolean; detail?: string } | null
  }
}

interface VerifyAndApplyRequest {
  server: ServerConfig
  password?: string | null
  savePassword: boolean
}

type PendingHostKeyAction =
  | { kind: 'start'; server: ServerConfig; interval?: number }
  | { kind: 'apply'; request: VerifyAndApplyRequest }

interface MonitorState {
  servers: ServerConfig[]
  snapshots: Record<string, MetricSnapshot>
  statuses: Record<string, string>
  errors: Record<string, string>
  history: HistoryEntry[]
  historyCorruptLines: number
  dataRoot: string
  sshConfigPath: string
  sshConfigAliases: string[]
  sshConfigCandidates: ServerConfig[]
  sshConfigError: string
  intervalSeconds: number
  agentStates: Record<string, AgentServerState>
  agentLoading: Record<string, boolean>
  agentGlobalLoading: boolean
  hostKeyChallenge: HostKeyChallenge | null
  pendingHostKeyAction: PendingHostKeyAction | null
  initialized: boolean
}

let unlisteners: UnlistenFn[] = []

export const useMonitorStore = defineStore('monitor', {
  state: (): MonitorState => ({
    servers: [],
    snapshots: {},
    statuses: {},
    errors: {},
    history: [],
    historyCorruptLines: 0,
    dataRoot: '',
    sshConfigPath: '',
    sshConfigAliases: [],
    sshConfigCandidates: [],
    sshConfigError: '',
    intervalSeconds: (() => {
      try {
        const val = Number(localStorage.getItem('serverpulse:interval_seconds'))
        return val >= 1 && val <= 300 ? val : 5
      } catch {
        return 5
      }
    })(),
    agentStates: {},
    agentLoading: {},
    agentGlobalLoading: false,
    hostKeyChallenge: null,
    pendingHostKeyAction: null,
    initialized: false,
  }),
  getters: {
    monitoredServers: (state) => state.servers.filter((server) => server.monitored),
    onlineCount: (state) => {
      const monitoredIds = new Set(
        state.servers.length > 0
          ? state.servers.filter((s) => s.monitored).map((s) => s.id)
          : Object.keys(state.statuses),
      )
      return Object.entries(state.statuses).filter(([id, status]) => monitoredIds.has(id) && status === 'online').length
    },
    unaddedCandidates: (state) =>
      state.sshConfigCandidates.filter(
        (candidate) =>
          !state.servers.some(
            (server) =>
              server.id.toLowerCase() === candidate.id.toLowerCase() ||
              server.host.toLowerCase() === candidate.host.toLowerCase(),
          ),
      ),
  },
  actions: {
    applyStartResult(result: StartResult, pending?: PendingHostKeyAction) {
      this.statuses = { ...this.statuses, [result.serverId]: result.status }
      if (result.hostKey && (result.status === 'host-key-required' || result.status === 'host-key-changed')) {
        this.hostKeyChallenge = result.hostKey
        this.pendingHostKeyAction = pending ?? null
      } else if (result.status === 'started') {
        this.pendingHostKeyAction = null
        setTimeout(() => {
          void this.refreshMonitoringState()
        }, 500)
      }
      return result
    },
    async init() {
      if (this.initialized) return
      try {
        const [servers, dataRoot] = await Promise.all([
          invoke<ServerConfig[]>('list_servers').catch((err) => {
            console.error('Failed to list servers:', err)
            this.errors._app = err instanceof Error ? err.message : String(err)
            return []
          }),
          invoke<string>('get_data_root').catch((err) => {
            console.error('Failed to get data root:', err)
            return ''
          }),
        ])
        this.servers = servers
        this.dataRoot = dataRoot
      } catch (error) {
        console.error('Store init error:', error)
      }

      await this.refreshSshConfig()

      try {
        unlisteners.forEach((unlisten) => unlisten())
        unlisteners = [
          await listen<ServerConfig[]>('servers.changed', (event) => {
            if (Array.isArray(event.payload)) {
              this.servers = event.payload
              void this.refreshSshConfig()
            }
          }),
          await listen<SnapshotEvent>('server.snapshot', (event) => {
            const id = event.payload.serverId
            this.snapshots = { ...this.snapshots, [id]: event.payload.payload }
            this.statuses = { ...this.statuses, [id]: 'online' }
            const nextErrors = { ...this.errors }
            delete nextErrors[id]
            this.errors = nextErrors
          }),
          await listen<StatusEvent>('server.status', (event) => {
            const id = event.payload.serverId
            this.statuses = { ...this.statuses, [id]: event.payload.payload.status }
            if (event.payload.payload.status === 'online') {
              const nextErrors = { ...this.errors }
              delete nextErrors[id]
              this.errors = nextErrors
            } else if (event.payload.payload.detail?.detail) {
              this.errors = { ...this.errors, [id]: event.payload.payload.detail.detail }
            }
          }),
          await listen<HostKeyChallenge>('server.host_key_required', (event) => {
            this.hostKeyChallenge = event.payload
          }),
          await listen<number>('interval.changed', (event) => {
            if (event.payload && event.payload >= 1 && event.payload <= 300) {
              this.intervalSeconds = event.payload
              try {
                localStorage.setItem('serverpulse:interval_seconds', String(event.payload))
              } catch {}
            }
          }),
        ]
      } catch (error) {
        console.warn('Event listen not available:', error)
      }

      if (typeof window !== 'undefined') {
        window.addEventListener('storage', (e) => {
          if (e.key === 'serverpulse:interval_seconds' && e.newValue) {
            const val = Number(e.newValue)
            if (val >= 1 && val <= 300) {
              this.intervalSeconds = val
            }
          }
        })
      }

      await Promise.all(this.servers.filter((server) => server.monitored).map((server) => this.start(server)))
      await this.refreshMonitoringState()
      setInterval(() => {
        void this.refreshMonitoringState()
      }, 2000)
      this.initialized = true
    },
    async setIntervalSeconds(seconds: number) {
      const clamped = Math.max(1, Math.min(300, Math.round(seconds || 5)))
      this.intervalSeconds = clamped
      try {
        localStorage.setItem('serverpulse:interval_seconds', String(clamped))
      } catch {}
      await invoke('set_all_monitoring_intervals', { intervalSeconds: clamped }).catch(() => undefined)
      await this.refreshMonitoringState()
    },
    async cycleInterval() {
      const presets = [2, 5, 10, 30, 60]
      const currentIndex = presets.indexOf(this.intervalSeconds)
      const nextIndex = currentIndex >= 0 ? (currentIndex + 1) % presets.length : 0
      await this.setIntervalSeconds(presets[nextIndex])
    },
    async refreshMonitoringState() {
      try {
        const res = await invoke<{
          snapshots: Record<string, MetricSnapshot>
          statuses: Record<string, string>
          errors: Record<string, string>
          intervalSeconds?: number
        }>('get_monitoring_state')
        if (res) {
          if (res.intervalSeconds && res.intervalSeconds >= 1 && res.intervalSeconds <= 300 && res.intervalSeconds !== this.intervalSeconds) {
            this.intervalSeconds = res.intervalSeconds
          }
          if (res.snapshots && Object.keys(res.snapshots).length > 0) {
            this.snapshots = { ...this.snapshots, ...res.snapshots }
          }
          if (res.statuses && Object.keys(res.statuses).length > 0) {
            this.statuses = { ...this.statuses, ...res.statuses }
          }
          if (res.errors) {
            const nextErrors: Record<string, string> = { ...res.errors }
            for (const [id, status] of Object.entries(this.statuses)) {
              if (status === 'online') {
                delete nextErrors[id]
              }
            }
            this.errors = nextErrors
          }
        }
      } catch (error) {
        console.error('Failed to get monitoring state:', error)
      }
    },
    async start(server: ServerConfig, customInterval?: number) {
      const interval = customInterval ?? this.intervalSeconds
      const result = await invoke<StartResult>('start_monitoring', { server, intervalSeconds: interval })
      return this.applyStartResult(result, { kind: 'start', server, interval })
    },
    async stop(serverId: string) {
      try {
        await invoke('stop_monitoring', { serverId })
      } finally {
        await invoke('clear_session_credential', { serverId }).catch(() => undefined)
      }
      if (this.pendingHostKeyAction?.kind === 'start' && this.pendingHostKeyAction.server.id === serverId) {
        this.pendingHostKeyAction = null
        this.hostKeyChallenge = null
      }
      this.statuses = { ...this.statuses, [serverId]: 'stopped' }
    },
    async clearSessionCredential(serverId: string) {
      await invoke('clear_session_credential', { serverId })
    },
    async probeHostKey(server: ServerConfig) {
      const challenge = await invoke<HostKeyChallenge>('probe_host_key', { server })
      this.hostKeyChallenge = challenge
      return challenge
    },
    async acceptHostKey() {
      if (!this.hostKeyChallenge) return null
      await invoke('accept_host_key', { challengeId: this.hostKeyChallenge.challengeId })
      const pending = this.pendingHostKeyAction
      this.hostKeyChallenge = null
      this.pendingHostKeyAction = null
      if (!pending) return null
      if (pending.kind === 'start') {
        return await this.start(pending.server, pending.interval)
      }
      return await this.verifyAndApplyServer(pending.request)
    },
    async forgetHostKey(server: ServerConfig) {
      await invoke('forget_host_key', { server })
      this.hostKeyChallenge = null
      return await this.probeHostKey(server)
    },
    async verifyAndApplyServer(request: VerifyAndApplyRequest) {
      const result = await invoke<ApplyServerResult>('verify_and_apply_server', { request })
      this.servers = result.servers ?? this.servers
      const retryRequest = { ...request, password: null }
      this.applyStartResult(result.start, { kind: 'apply', request: retryRequest })
      if (result.start.status !== 'host-key-required' && result.start.status !== 'host-key-changed') {
        this.pendingHostKeyAction = null
      }
      return result
    },
    async reloadServers() {
      const servers = await invoke<ServerConfig[]>('list_servers')
      this.servers = servers
      await this.refreshSshConfig()
      await Promise.all(
        servers
          .filter((server) => server.monitored && !this.statuses[server.id])
          .map((server) => this.start(server).catch((error) => {
            this.errors[server.id] = error instanceof Error ? error.message : String(error)
          })),
      )
    },
    async refreshSshConfig() {
      try {
        const info = await invoke<SshConfigInfo>('inspect_ssh_config')
        this.sshConfigPath = info.path ?? ''
        this.sshConfigAliases = info.aliases ?? []
        this.sshConfigCandidates = info.candidates ?? []
        this.sshConfigError = info.error ?? ''
      } catch (error) {
        this.sshConfigError = error instanceof Error ? error.message : String(error)
      }
    },
    async importCandidate(candidate: ServerConfig, startNow = true) {
      const server: ServerConfig = {
        ...candidate,
        monitored: startNow,
        passwordless: true,
      }
      await this.saveServer(server)
    },
    async importAllCandidates(startNow = true) {
      const unadded = this.unaddedCandidates
      for (const candidate of unadded) {
        await this.importCandidate(candidate, startNow)
      }
    },
    async saveServer(server: ServerConfig, password = '', savePassword = false) {
      const existing = this.servers.find((candidate) => candidate.id !== server.id && candidate.host.toLowerCase() === server.host.toLowerCase())
      if (existing && this.statuses[existing.id]) {
        await this.stop(existing.id).catch(() => undefined)
      }
      const result = await this.verifyAndApplyServer({
        server,
        password: password || null,
        savePassword,
      })
      if (server.passwordless) {
        await invoke('delete_credential', { server }).catch(() => undefined)
      }
      return result
    },
    async toggleServerMonitored(server: ServerConfig) {
      const updated: ServerConfig = {
        ...server,
        monitored: !server.monitored,
      }
      await this.saveServer(updated)
    },
    async deleteServer(serverId: string) {
      await this.stop(serverId).catch(() => undefined)
      this.servers = await invoke<ServerConfig[]>('delete_server', { serverId })
      delete this.snapshots[serverId]
      delete this.statuses[serverId]
      delete this.errors[serverId]
    },
    async recheck(server: ServerConfig) {
      await invoke('recheck_monitoring', { server })
      this.statuses = { ...this.statuses, [server.id]: 'rechecking' }
      setTimeout(() => {
        void this.refreshMonitoringState()
      }, 500)
    },
    async openWindow(kind: 'manage' | 'history') {
      await invoke('open_window', { kind })
    },
    async hideMain() {
      await invoke('hide_main_window')
    },
    async closeMain() {
      await invoke('close_main_window')
    },
    async loadHistory(day: string) {
      const response = await invoke<{ entries: HistoryEntry[]; corruptLines: number }>('query_history', { day })
      this.history = response.entries
      this.historyCorruptLines = response.corruptLines
    },
    async fetchAgentStates() {
      try {
        const states = await invoke<Record<string, AgentServerState>>('get_agent_states')
        this.agentStates = states || {}
      } catch (err) {
        console.error('Failed to fetch agent states:', err)
      }
    },
    async checkAgentStatus(serverId: string) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('check_agent_status', { serverId })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async checkAllAgentStatuses() {
      this.agentGlobalLoading = true
      try {
        const states = await invoke<Record<string, AgentServerState>>('check_all_agent_statuses')
        this.agentStates = states || {}
        return states
      } finally {
        this.agentGlobalLoading = false
      }
    },
    async deployAndStartAgent(serverId: string, intervalSeconds = 5, retentionDays = 30) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('deploy_and_start_agent', {
          serverId,
          intervalSeconds,
          retentionDays,
        })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async stopAgent(serverId: string) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('stop_agent', { serverId })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async restartAgent(serverId: string) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('restart_agent', { serverId })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async updateAgentConfig(serverId: string, intervalSeconds: number, retentionDays: number) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('update_agent_config', {
          serverId,
          intervalSeconds,
          retentionDays,
        })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async uninstallAgent(serverId: string) {
      this.agentLoading[serverId] = true
      try {
        const state = await invoke<AgentServerState>('uninstall_agent', { serverId })
        this.agentStates = { ...this.agentStates, [serverId]: state }
        return state
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async pullAndMergeRecords(serverId: string, cleanRemote: boolean) {
      this.agentLoading[serverId] = true
      try {
        const result = await invoke<AgentMergeResult>('pull_and_merge_records', {
          serverId,
          cleanRemote,
        })
        await this.fetchAgentStates()
        return result
      } finally {
        this.agentLoading[serverId] = false
      }
    },
    async pullAndMergeAllRecords(cleanRemote: boolean) {
      this.agentGlobalLoading = true
      try {
        const results = await invoke<Record<string, AgentMergeResult>>('pull_and_merge_all_records', {
          cleanRemote,
        })
        await this.fetchAgentStates()
        return results
      } finally {
        this.agentGlobalLoading = false
      }
    },
  },
})
