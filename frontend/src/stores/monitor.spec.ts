import { setActivePinia, createPinia } from 'pinia'
import { describe, expect, it, vi } from 'vitest'
import { useMonitorStore } from './monitor'

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(async (command: string) => {
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
    return undefined
  }),
}))

vi.mock('@tauri-apps/api/event', () => ({
  listen: vi.fn(async () => () => undefined),
}))

describe('monitor store', () => {
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
})
