import { expect, test } from '@playwright/test'

for (const status of ['partial', 'unavailable', 'ok', null] as const) {
  test(`GPU collection ${status ?? 'legacy'} keeps readable cards and reports failures`, async ({ page }) => {
    await page.addInitScript(() => {
      window.__TAURI_INTERNALS__ = {
        metadata: { current: 'main', mutableWindows: ['main'], packageName: 'serverpulse' },
        transformCallback() { return 1 },
        invoke: async (cmd: string, args?: Record<string, unknown>) => {
          if (cmd === 'list_servers') return [{
            id: 'test-gpu', label: '3090', host: 'test-gpu', monitored: true, passwordless: true,
          }]
          if (cmd === 'get_data_root') return 'C:/ServerPulse'
          if (cmd === 'start_monitoring') return {
            serverId: (args?.server as { id: string })?.id, status: 'started',
          }
          if (cmd.startsWith('plugin:event|')) return 'event-1'
          return undefined
        },
      }
    })
    await page.goto('/')
    await expect(page.locator('.server-card')).toBeVisible()
    await page.evaluate((gpuQueryStatus) => {
      const app = (document.querySelector('#app') as any).__vue_app__
      const state = app.config.globalProperties.$pinia.state.value.monitor
      const snapshot: Record<string, unknown> = {
        hostname: 'test-gpu', protocolVersion: 2,
        cpuPercent: 5.7, memoryTotalMib: 128512, memoryUsedMib: 23040, memoryPercent: 17.9,
        cpuUserStatus: 'ok', cpuUsers: [], memoryUserStatus: 'ok', memoryUsers: [], disks: [],
        gpus: gpuQueryStatus === 'unavailable' ? [] : [0, 2].map((index) => ({
          index, name: 'NVIDIA GeForce RTX 3090', uuid: `GPU-test-${index}`,
          utilization: 12, memoryUsedMib: 1024, memoryTotalMib: 24576, temperatureC: 30,
          powerDrawW: 20, powerLimitW: 350, fanPercent: 0,
          userMemoryStatus: 'unavailable', userMemory: [], unmappedProcesses: 0,
        })),
      }
      if (gpuQueryStatus !== null) snapshot.gpuQueryStatus = gpuQueryStatus
      state.snapshots = { 'test-gpu': snapshot }
      state.statuses = { 'test-gpu': 'online' }
    }, status)

    await expect(page.locator('.metric', { hasText: 'CPU' })).toContainText('5.7%')
    await expect(page.locator('.gpu-mini-card')).toHaveCount(status === 'unavailable' ? 0 : 2)
    if (status !== 'unavailable') {
      await expect(page.locator('.gpu-mini-card').last()).toContainText('GPU 2 · NVIDIA RTX 3090')
      await expect(page.locator('.gpu-mini-card').last()).toContainText('1.0 / 24.0 GB')
    }
    if (status === 'partial' || status === 'unavailable') {
      await expect(page.locator('.gpu-query-warning')).toContainText(
        status === 'partial' ? '部分 GPU 数据不可用' : 'GPU 数据采集失败',
      )
    } else {
      await expect(page.locator('.gpu-query-warning')).toHaveCount(0)
    }
  })
}
