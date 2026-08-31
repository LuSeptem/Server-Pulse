import { test, expect } from '@playwright/test'

// Regression test: system memory must display its total (used / total GB)
// on both the main window card and the History page. The Tauri bridge is
// stubbed; NOTE the stub must be defined inside addInitScript because
// passing the method-bearing object as a serialized argument strips functions.
function tauriStubOptions(serverCount: number, withHistory: boolean) {
  const servers = Array.from({ length: serverCount }, (_, i) => ({
    id: `srv-${i}`,
    label: `test-host-${i}`,
    host: `host-${i}.example.test`,
    user: `user${i}`,
    port: 22,
    monitored: true,
    passwordless: true,
  }))
  const historyEntry = {
    Version: 2,
    Record: {
      Timestamp: '2026-08-31T10:00:00Z',
      SampleCount: 1,
      Servers: [
        {
          Id: 'srv-0',
          Label: 'test-host-0',
          Host: 'host-0.example.test',
          CpuPercent: 42.5,
          MemoryPercent: 72.1,
          MemoryUsedMiB: 94486, // 92.3 GB
          MemoryTotalMiB: 131072, // 128 GB
          Gpus: [],
        },
      ],
    },
  }
  return { servers, history: withHistory ? { entries: [historyEntry], corruptLines: 0 } : null }
}

function installStub(opts: ReturnType<typeof tauriStubOptions>) {
  window.__TAURI_INTERNALS__ = {
    metadata: { current: 'main', mutableWindows: ['main'], packageName: 'serverpulse' },
    transformCallback() {
      return 1
    },
    invoke: async (cmd: string, args?: Record<string, unknown>) => {
      if (cmd === 'list_servers') return opts.servers
      if (cmd === 'get_data_root') return 'C:/ServerPulse'
      if (cmd === 'start_monitoring') {
        return { serverId: String(args?.server?.id ?? 'unknown'), status: 'started' }
      }
      if (cmd === 'query_history') return opts.history
      if (cmd.startsWith('plugin:event|')) return 'evt-1'
      return undefined
    },
  }
}

// 94486 MiB used / 131072 MiB total → "92.3 / 128.0 GB" (card) / "128 GB" (chip)
test('main window MEM metric shows used/total GB', async ({ page }) => {
  await page.setViewportSize({ width: 440, height: 620 })
  await page.addInitScript(installStub, tauriStubOptions(1, false))
  await page.goto('/')
  await expect(page.locator('.server-card').first()).toBeVisible()

  // Feed the store a real-shaped snapshot the way a server-snapshot event would.
  await page.evaluate(() => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const app: any = (document.querySelector('#app') as any)?.__vue_app__
    if (!app) throw new Error('Vue app instance not found')
    const state = app.config.globalProperties.$pinia.state.value.monitor
    state.snapshots = {
      'srv-0': {
        hostname: 'host-0',
        protocolVersion: 2,
        cpuPercent: 42.5,
        memoryTotalMib: 131072,
        memoryUsedMib: 94486,
        memoryPercent: 72.1,
        loadOne: 1,
        loadFive: 1,
        loadFifteen: 1,
        uptimeSeconds: 100000,
        cpuUserStatus: 'ok',
        cpuUsers: [],
        memoryUserStatus: 'ok',
        memoryUsers: [],
        gpus: [],
        disks: [],
      },
    }
  })

  const memCell = page.locator('.metric', { hasText: 'MEM' }).first()
  await expect(memCell).toContainText('72.1%')
  await expect(memCell).toContainText('92.3 / 128.0 GB')
})

test('history page RAM chip shows total memory', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 })
  await page.addInitScript(installStub, tauriStubOptions(1, true))
  await page.goto('/?view=history')

  const ramChip = page.locator('.stat-chip', { hasText: 'RAM' }).first()
  await expect(ramChip).toContainText('72.1%')
  await expect(ramChip).toContainText('128 GB')
})
