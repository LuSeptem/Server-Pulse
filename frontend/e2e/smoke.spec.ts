import { test, expect } from '@playwright/test'

test('renders the Server Pulse shell', async ({ page }) => {
  await page.goto('/')
  await expect(page.getByText('Server monitor')).toBeVisible()
})
