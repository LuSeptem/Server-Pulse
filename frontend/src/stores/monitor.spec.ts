import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { invoke } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import { useMonitorStore } from './monitor'

async function defaultInvoke(command: string, args?: any) {
  if (command === 'list_servers') {
    return [{ id: '3090', label: 'RTX 3090', host: '3090', monitored: true, passwordless: true }]
  }
  if (command === 'get_data_root') {
    return '/tmp/ServerPulse'
  }
  if (command === 'inspect_ssh_config') {
    return {
      path: '/home/test/.ssh/config',
      aliases: ['3090', '409'],
      candidates: [
        { id: '3090', label: '3090', host: '3090', monitored: false, passwordless: true },
        { id: '409', label: '409', host: '409', user: 'xzm', port: 22, monitored: false, passwordless: true },
      ],
      error: null,
    }
  }
  if (command === 'save_server') {
    return [
      { id: '3090', label: 'RTX 3090', host: '3090', monitored: true, passwordless: true },
      { id: '409', label: '409', host: '409', user: 'xzm', port: 22, monitored: true, passwordless: true },
    ]
  }
  if (command === 'start_monitoring') {
    return { serverId: args?.server?.id, status: 'started', detail: null, hostKey: null }
  }
  if (command === 'query_history') {
    return {
      entries: [],
      corruptLines: 0,
      diskAttribution: [
        {
          kind: 'diskAttribution', serverId: '3090', scannedAt: '2026-08-20T03:12:45Z',
          mount: '/data', status: 'ok', skippedEntries: 0,
          users: [{ uid: '1000', name: 'alice', usedMib: 1234567 }],
        },
      ],
    }
  }
  if (command === 'trigger_disk_scan') {
    return { serverId: args?.serverId, status: 'launched', detail: null }
  }
  if (command === 'verify_and_apply_server') {
    const server = args?.request?.server
    const servers = server?.id === '409'
      ? [
          { id: '3090', label: 'RTX 3090', host: '3090', monitored: true, passwordless: true },
          server,
        ]
      : server ? [server] : []
    return {
      servers,
      start: { serverId: server?.id, status: server?.monitored ? 'started' : 'verified', detail: null, hostKey: null },
    }
  }
  return undefined
}

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(defaultInvoke),
}))

vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(async () => () => undefined),
}))

describe('monitor store', () => {
  beforeEach(() => {
    vi.mocked(invoke).mockImplementation(defaultInvoke)
  })

  it('loads the seed servers and data root', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    expect(store.servers).toHaveLength(1)
    expect(store.servers[0].id).toBe('3090')
    expect(store.dataRoot).toBe('/tmp/ServerPulse')
    expect(store.unaddedCandidates).toHaveLength(1)
    expect(store.unaddedCandidates[0].id).toBe('409')
  })

  it('keeps initializing when one monitored server fails to start', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'startup-failure', label: 'Startup failure', host: 'startup-failure', monitored: true, passwordless: true }
    vi.mocked(invoke)
      .mockResolvedValueOnce([server])
      .mockResolvedValueOnce('/tmp/ServerPulse')
      .mockResolvedValueOnce({ path: '/home/test/.ssh/config', aliases: [], candidates: [], error: null })
      .mockRejectedValueOnce(new Error('host key probe failed'))
      .mockResolvedValueOnce({ snapshots: {}, statuses: {}, errors: {}, intervalSeconds: 5 })

    await store.init()

    expect(store.initialized).toBe(true)
    expect(store.statuses[server.id]).toBe('offline')
    expect(store.errors[server.id]).toBe('host key probe failed')
  })

  it('imports an unadded candidate', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    await store.importCandidate(store.unaddedCandidates[0])
    expect(store.servers).toHaveLength(2)
  })

  it('counts only online servers', () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    store.statuses = { a: 'online', b: 'offline', c: 'online' }
    expect(store.onlineCount).toBe(2)
  })

  it('passes a session-only password through the apply request without saving it', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'session-1', label: 'Session', host: 'session-1', monitored: false, passwordless: false }
    await store.saveServer(server, 'one-run-secret', false)
    expect(invoke).toHaveBeenCalledWith('verify_and_apply_server', {
      request: { server, password: 'one-run-secret', savePassword: false },
    })
    expect(invoke).not.toHaveBeenCalledWith('save_credential', expect.anything())
  })

  it('does not keep a password in a pending host-key retry request', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'pending-secret', label: 'Pending', host: 'pending-secret', monitored: true, passwordless: false }
    vi.mocked(invoke).mockResolvedValueOnce({
      servers: [server],
      start: {
        serverId: server.id,
        status: 'host-key-required',
        detail: null,
        hostKey: {
          challengeId: 'challenge-secret',
          server: server.host,
          port: 22,
          keys: [{ algorithm: 'ssh-ed25519', fingerprint: 'SHA256:test' }],
          state: 'unknown',
        },
      },
    })

    await store.saveServer(server, 'one-run-secret', true)
    expect(store.pendingHostKeyAction).toMatchObject({
      kind: 'apply',
      request: { password: null, savePassword: true },
    })
    expect(JSON.stringify(store.pendingHostKeyAction)).not.toContain('one-run-secret')
  })

  it('retries the pending action after host-key acceptance', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'host-key-1', label: 'Host key', host: 'host-key-1', monitored: true, passwordless: true }
    store.hostKeyChallenge = {
      challengeId: 'challenge-1',
      server: 'host-key-1',
      port: 22,
      keys: [{ algorithm: 'ssh-ed25519', fingerprint: 'SHA256:test' }],
      state: 'unknown',
    }
    store.pendingHostKeyAction = { kind: 'start', server }
    vi.mocked(invoke).mockResolvedValueOnce(undefined)
    vi.mocked(invoke).mockResolvedValueOnce({ serverId: server.id, status: 'started', detail: null, hostKey: null })
    const result = await store.acceptHostKey()
    expect(result).toMatchObject({ status: 'started' })
    expect(store.hostKeyChallenge).toBeNull()
    expect(store.pendingHostKeyAction).toBeNull()
  })

  it('surfaces a host-key challenge returned by recheck', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'recheck-host-key', label: 'Recheck host key', host: 'recheck-host-key', monitored: true, passwordless: true }
    const hostKey = {
      challengeId: 'recheck-challenge',
      server: server.host,
      port: 22,
      keys: [{ algorithm: 'ssh-ed25519', fingerprint: 'SHA256:recheck' }],
      state: 'unknown' as const,
    }
    vi.mocked(invoke).mockResolvedValueOnce({
      serverId: server.id,
      status: 'host-key-required',
      detail: 'Verify the host fingerprint before connecting.',
      hostKey,
    })

    await store.recheck(server)

    expect(store.statuses[server.id]).toBe('host-key-required')
    expect(store.hostKeyChallenge).toEqual(hostKey)
    expect(store.pendingHostKeyAction).toMatchObject({ kind: 'start', server })
  })

  it('surfaces a recheck command error instead of leaving rechecking forever', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const server = { id: 'recheck-failure', label: 'Recheck failure', host: 'recheck-failure', monitored: true, passwordless: true }
    vi.mocked(invoke).mockRejectedValueOnce(new Error('host key probe timed out'))

    await expect(store.recheck(server)).rejects.toThrow('host key probe timed out')
    expect(store.statuses[server.id]).toBe('offline')
    expect(store.errors[server.id]).toBe('host key probe timed out')
  })

  it('keeps a server selection change received while initialization is loading', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    const staleServer = { id: 'race-server', label: 'Race server', host: 'race-server', monitored: false, passwordless: true }
    const selectedServer = { ...staleServer, monitored: true }
    const listeners = new Map<string, (event: { payload: unknown }) => void>()
    let releaseSshConfig!: () => void
    let markSshConfigStarted!: () => void
    const sshConfigStarted = new Promise<void>((resolve) => { markSshConfigStarted = resolve })
    const sshConfigGate = new Promise<void>((resolve) => { releaseSshConfig = resolve })

    vi.mocked(listen).mockImplementation(async (event, handler) => {
      listeners.set(event, handler as (event: { payload: unknown }) => void)
      return () => listeners.delete(event)
    })
    vi.mocked(invoke).mockImplementation(async (command: string) => {
      if (command === 'list_servers') return [staleServer]
      if (command === 'get_data_root') return '/tmp/ServerPulse'
      if (command === 'inspect_ssh_config') {
        markSshConfigStarted()
        await sshConfigGate
        return { path: '/home/test/.ssh/config', aliases: [], candidates: [], error: null }
      }
      if (command === 'start_monitoring') {
        return { serverId: 'race-server', status: 'started', detail: null, hostKey: null }
      }
      if (command === 'get_monitoring_state') return { snapshots: {}, statuses: {}, errors: {}, intervalSeconds: 5 }
      return undefined
    })

    const initPromise = store.init()
    await sshConfigStarted
    listeners.get('servers.changed')?.({ payload: [selectedServer] })
    releaseSshConfig()
    await initPromise

    expect(store.servers).toEqual([selectedServer])
  })

  it('loads disk attribution with history', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    await store.loadHistory('2026-08-21')
    expect(store.diskAttribution).toHaveLength(1)
    expect(store.diskAttribution[0].mount).toBe('/data')
  })

  it('triggers disk scan and stores status', async () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    await store.init()
    const result = await store.triggerDiskScan('3090')
    expect(result.status).toBe('launched')
    expect(store.diskScans['3090'].state).toBe('running')
  })
})
