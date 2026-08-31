import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const INITIAL_SERVERS = [
  { id: 'gpu-a', label: 'GPU A', host: 'gpu-a', monitored: true, passwordless: true },
  { id: 'gpu-b', label: 'GPU B', host: 'gpu-b', monitored: false, passwordless: true },
]

/**
 * Two-window selection-sync harness.
 *
 * Emulates the Rust side faithfully for the selection flow:
 *  - `verify_and_apply_server` persists the server list, stops the task when
 *    unselected, and broadcasts `servers.changed` to ALL windows (app.emit),
 *    exactly like `persist_server` in src-tauri/src/main.rs.
 *  - `start_monitoring`/`stop_monitoring` track live monitoring tasks and
 *    broadcast `server.status`/`server.snapshot` to ALL windows.
 *
 * Each "window" gets a fresh module graph (vi.resetModules) and a fresh
 * Pinia, mirroring the separate Main/Manage webviews in the real app.
 */

type Server = {
  id: string
  label: string
  host: string
  user?: string | null
  port?: number | null
  monitored: boolean
  passwordless: boolean
}

/**
 * Faithful port of tauri 2.x `is_event_name_valid`
 * (tauri/src/event/event_name.rs): alphanumeric, `-`, `/`, `:`, `_`.
 * No dots. Tauri rejects invalid names in `listen` and silently drops them
 * on `emit` — the mocks enforce the listen side so a regression fails here
 * instead of in production.
 */
export function tauriEventNameValid(event: string): boolean {
  return [...event].every((c) => /[A-Za-z0-9\-/:_]/.test(c))
}

type EventListener = (event: { payload: unknown }) => void

interface FakeBackend {
  servers: Server[]
  tasks: Map<string, true>
  statuses: Record<string, string>
  snapshots: Record<string, unknown>
  errors: Record<string, string>
  listeners: Map<string, Set<EventListener>>
  emit(event: string, payload: unknown): void
  invoke(command: string, args?: any): Promise<unknown>
  startTask(server: Server): void
}

function createBackend(initialServers: Server[]): FakeBackend {
  function startTask(server: Server) {
    backend.tasks.set(server.id, true)
    backend.statuses[server.id] = 'online'
    delete backend.errors[server.id]
    const snapshot = {
      hostname: server.host,
      protocolVersion: 2,
      cpuPercent: 42,
      memoryTotalMib: 1024,
      memoryUsedMib: 512,
      memoryPercent: 50,
      loadOne: 1,
      loadFive: 1,
      loadFifteen: 1,
      uptimeSeconds: 100,
      cpuUserStatus: 'ok',
      cpuUsers: [],
      memoryUserStatus: 'ok',
      memoryUsers: [],
      gpus: [],
      disks: [],
    }
    backend.snapshots[server.id] = snapshot
    backend.emit('server-status', {
      serverId: server.id,
      timestamp: new Date().toISOString(),
      sequence: 1,
      payload: { status: 'online', detail: null },
    })
    backend.emit('server-snapshot', {
      serverId: server.id,
      timestamp: new Date().toISOString(),
      sequence: 1,
      payload: snapshot,
    })
  }
  const backend: FakeBackend = {
    startTask,
    servers: initialServers.map((server) => ({ ...server })),
    tasks: new Map(),
    statuses: {},
    snapshots: {},
    errors: {},
    listeners: new Map(),
    emit(event, payload) {
      const handlers = [...(backend.listeners.get(event) ?? [])]
      for (const handler of handlers) {
        handler({ payload })
      }
    },
    async invoke(command, args) {
      switch (command) {
        case 'list_servers':
          return backend.servers.map((server) => ({ ...server }))
        case 'get_data_root':
          return '/tmp/ServerPulse'
        case 'inspect_ssh_config':
          return { path: '', aliases: [], candidates: [], error: null }
        case 'verify_and_apply_server': {
          const server: Server = args?.request?.server
          const index = backend.servers.findIndex(
            (existing) =>
              existing.id.toLowerCase() === server.id.toLowerCase() ||
              existing.host.toLowerCase() === server.host.toLowerCase(),
          )
          if (index >= 0) {
            backend.servers[index] = { ...server }
          } else {
            backend.servers.push({ ...server })
          }
          if (!server.monitored) {
            backend.tasks.delete(server.id)
            backend.statuses[server.id] = 'stopped'
          }
          // persist_server: app.emit("servers-changed", &servers)
          backend.emit('servers-changed', backend.servers.map((s) => ({ ...s })))
          if (server.monitored) {
            backend.startTask(server)
            return {
              servers: backend.servers.map((s) => ({ ...s })),
              start: { serverId: server.id, status: 'started', detail: null, hostKey: null },
            }
          }
          return {
            servers: backend.servers.map((s) => ({ ...s })),
            start: { serverId: server.id, status: 'verified', detail: null, hostKey: null },
          }
        }
        case 'start_monitoring': {
          backend.startTask(args?.server)
          return { serverId: args?.server?.id, status: 'started', detail: null, hostKey: null }
        }
        case 'stop_monitoring':
          backend.tasks.delete(args?.serverId)
          backend.statuses[args?.serverId] = 'stopped'
          return null
        case 'clear_session_credential':
          return null
        case 'get_monitoring_state':
          return {
            snapshots: { ...backend.snapshots },
            statuses: { ...backend.statuses },
            errors: { ...backend.errors },
            intervalSeconds: 5,
          }
        case 'set_all_monitoring_intervals':
          return null
        case 'query_disk_attribution':
          return { diskAttribution: [] }
        default:
          return undefined
      }
    },
  }
  return backend
}

let backend = createBackend(INITIAL_SERVERS)

beforeEach(() => {
  // A fresh backend per test: each test emulates a clean app process.
  backend = createBackend(INITIAL_SERVERS)
})

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(async (command: string, args?: any) => backend.invoke(command, args)),
}))
vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(async (event: string, handler: EventListener) => {
    // Faithful to tauri 2.x: invalid event names reject the listen call.
    if (!tauriEventNameValid(event)) {
      throw new Error(
        `invalid args 'event' for command 'listen': Event name must include only alphanumeric characters, '-', '/', ':' and '_'.`,
      )
    }
    const handlers = backend.listeners.get(event) ?? new Set<EventListener>()
    handlers.add(handler)
    backend.listeners.set(event, handlers)
    return () => handlers.delete(handler)
  }),
}))

async function openWindow() {
  vi.resetModules()
  setActivePinia(createPinia())
  const { useMonitorStore } = await import('./monitor')
  const store = useMonitorStore()
  await store.init()
  return store
}

describe('manage ↔ main selection sync (two windows, shared backend)', () => {
  it('selecting a server in manage adds it to the main window live', async () => {
    const main = await openWindow()
    const manage = await openWindow()

    expect(main.monitoredServers.map((s: Server) => s.id)).toEqual(['gpu-a'])

    const b = manage.servers.find((s: Server) => s.id === 'gpu-b')!
    await manage.toggleServerMonitored(b)

    expect(manage.monitoredServers.map((s: Server) => s.id)).toEqual(expect.arrayContaining(['gpu-b']))
    // The main window must pick up the new card without a restart.
    expect(main.monitoredServers.map((s: Server) => s.id)).toEqual(expect.arrayContaining(['gpu-b']))
    // ...and its live snapshot must arrive through the broadcast events.
    expect(main.snapshots['gpu-b']).toBeTruthy()
    expect(main.statuses['gpu-b']).toBe('online')
  })

  it('deselecting a server in manage removes it from the main window live', async () => {
    const main = await openWindow()
    const manage = await openWindow()

    expect(main.monitoredServers.map((s: Server) => s.id)).toEqual(['gpu-a'])
    expect(main.snapshots['gpu-a']).toBeTruthy()

    const a = manage.servers.find((s: Server) => s.id === 'gpu-a')!
    await manage.toggleServerMonitored(a)

    expect(manage.monitoredServers.map((s: Server) => s.id)).not.toContain('gpu-a')
    // The main window must drop the card without a restart.
    expect(main.monitoredServers.map((s: Server) => s.id)).not.toContain('gpu-a')
    // The live monitoring task itself must have been stopped on the backend.
    expect(backend.tasks.has('gpu-a')).toBe(false)
  })
})
