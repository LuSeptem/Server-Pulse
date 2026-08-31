import { test, expect } from '@playwright/test'

// Regression test: the main window's header (title + edge/History/Manage/
// minimize/close buttons) must stay pinned at the top while the server list
// scrolls. Previously the whole document scrolled, so scrolling down hid the
// header and the user could no longer minimize or close the widget.
//
// The stubbed Tauri bridge feeds the store enough monitored servers to make
// the card list taller than the (440x620, matching the real main window)
// viewport, so the scroll that triggered the bug actually happens.
// NOTE: the stub must be defined inside addInitScript — passing the object
// with methods as a serialized argument would strip its functions.
function tauriServers(count: number) {
  return Array.from({ length: count }, (_, i) => ({
    id: `srv-${i}`,
    label: `test-host-${i}`,
    host: `host-${i}.example.test`,
    user: `user${i}`,
    port: 22,
    monitored: true,
    passwordless: true,
  }))
}

test('header window controls stay pinned while the server list scrolls', async ({ page }) => {
  await page.setViewportSize({ width: 440, height: 620 })
  await page.addInitScript((serverList: unknown[]) => {
    let id = 0
    window.__TAURI_INTERNALS__ = {
      metadata: { current: 'main', mutableWindows: ['main'], packageName: 'serverpulse' },
      transformCallback(callback: unknown) {
        return ++id
      },
      invoke: async (cmd: string, args?: Record<string, unknown>) => {
        if (cmd === 'list_servers') return serverList
        if (cmd === 'get_data_root') return 'C:/ServerPulse'
        if (cmd === 'start_monitoring') {
          return { serverId: String(args?.server?.id ?? 'unknown'), status: 'started' }
        }
        if (cmd.startsWith('plugin:event|')) return `evt-${++id}`
        return undefined
      },
    }
  }, tauriServers(12))

  await page.goto('/')
  await expect(page.locator('.server-card').first()).toBeVisible()

  // The bug only exists when the card content overflows the viewport —
  // assert we are actually exercising an overflowing list.
  const overflow = await page.evaluate(() => {
    const list = document.querySelector<HTMLElement>('.server-list')
    if (!list) return { scrollable: false }
    return {
      scrollable:
        list.scrollHeight > list.clientHeight + 40 ||
        document.documentElement.scrollHeight > window.innerHeight + 40,
    }
  })
  expect(overflow.scrollable).toBe(true)

  // Scroll the page and/or the list as far down as possible.
  await page.evaluate(() => {
    window.scrollTo(0, document.documentElement.scrollHeight)
    const list = document.querySelector<HTMLElement>('.server-list')
    if (list) list.scrollTop = list.scrollHeight
  })
  await page.waitForTimeout(200)

  // The close control must still be fully inside the viewport, i.e. the user
  // can still minimize/close the widget after scrolling to the bottom.
  const closeBtn = page.locator('.header-actions button[title="Close"]')
  await expect(closeBtn).toBeVisible()
  const box = await closeBtn.boundingBox()
  expect(box).not.toBeNull()
  expect(box!.y).toBeGreaterThanOrEqual(0)
  expect(box!.y + box!.height).toBeLessThanOrEqual(620)

  // Same for the whole header row (title + all window controls).
  const headerBox = await page.locator('.window-header').boundingBox()
  expect(headerBox).not.toBeNull()
  expect(headerBox!.y).toBeGreaterThanOrEqual(0)
})
