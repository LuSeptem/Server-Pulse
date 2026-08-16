import { invoke } from '@tauri-apps/api/core'
import { listen, type UnlistenFn } from '@tauri-apps/api/event'
import { defineStore } from 'pinia'
import type { HistoryEntry, MetricSnapshot, ServerConfig, SshConfigInfo } from '../types'

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
    initialized: false,
  }),
  getters: {
    onlineCount: (state) => Object.values(state.statuses).filter((value) => value === 'online').length,
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
    async init() {
      if (this.initialized) return
      try {
        this.servers = await invoke<ServerConfig[]>('list_servers')
        this.dataRoot = await invoke<string>('get_data_root')
      } catch (error) {
        // Keep the web preview and Playwright shell usable outside Tauri.
        this.servers = []
        this.dataRoot = 'Tauri runtime required for live data'
        this.errors._app = error instanceof Error ? error.message : String(error)
        this.initialized = true
        return
      }
      await this.refreshSshConfig()
      unlisteners.forEach((unlisten) => unlisten())
      unlisteners = [
        await listen<SnapshotEvent>('server.snapshot', (event) => {
          this.snapshots[event.payload.serverId] = event.payload.payload
          this.statuses[event.payload.serverId] = 'online'
        }),
        await listen<StatusEvent>('server.status', (event) => {
          this.statuses[event.payload.serverId] = event.payload.payload.status
          if (event.payload.payload.detail?.detail) {
            this.errors[event.payload.serverId] = event.payload.payload.detail.detail
          }
        }),
      ]
      await Promise.all(this.servers.filter((server) => server.monitored).map((server) => this.start(server)))
      this.initialized = true
    },
    async start(server: ServerConfig) {
      await invoke('start_monitoring', { server, intervalSeconds: 5 })
      this.statuses[server.id] = 'connecting'
    },
    async stop(serverId: string) {
      await invoke('stop_monitoring', { serverId })
      this.statuses[serverId] = 'stopped'
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
      this.servers = await invoke<ServerConfig[]>('save_server', { server })
      if (server.passwordless) {
        await invoke('delete_credential', { server })
      } else if (savePassword && password) {
        await invoke('save_credential', { server, password })
      }
      if (server.monitored) {
        await this.start(server)
      } else {
        await this.stop(server.id)
      }
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
      this.statuses[server.id] = 'rechecking'
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
  },
})
