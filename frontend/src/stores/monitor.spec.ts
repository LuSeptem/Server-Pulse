import { setActivePinia, createPinia } from 'pinia'
import { describe, expect, it, vi } from 'vitest'
import { useMonitorStore } from './monitor'

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(async (command: string) => {
    if (command === 'list_servers') {
      return [{ id: '3090', label: 'RTX 3090', host: '3090', monitored: true }]
    }
    if (command === 'get_data_root') {
      return '/tmp/ServerPulse'
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
  })

  it('counts only online servers', () => {
    setActivePinia(createPinia())
    const store = useMonitorStore()
    store.statuses = { a: 'online', b: 'offline', c: 'online' }
    expect(store.onlineCount).toBe(2)
  })
})
