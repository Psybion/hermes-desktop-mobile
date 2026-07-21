const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')

const URL = process.env.HERMES_DESKTOP_WEB_URL || 'http://127.0.0.1:9122/'
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined

;(async () => {
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] })
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2
  })
  try {
    await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60_000 })
    await page.waitForSelector("[data-slot='composer-root']", { timeout: 60_000 })
    const rightToggle = page.getByRole('button', { name: 'Show right sidebar' })
    await rightToggle.click()
    const pane = page.locator("aside[aria-label='Right sidebar']")
    await pane.waitFor({ state: 'visible' })
    await page.waitForTimeout(300)
    const opened = await pane.boundingBox()
    const screenshotPath = process.env.HERMES_MOBILE_PANE_SCREENSHOT ||
      path.join(__dirname, '..', 'qa-output', 'mobile-right-sidebar.png')
    fs.mkdirSync(path.dirname(screenshotPath), { recursive: true })
    await page.screenshot({ path: screenshotPath, fullPage: true })
    await rightToggle.click()
    await pane.waitFor({ state: 'detached' })
    const state = await page.evaluate(() => ({
      main: document.querySelector("[data-slot='composer-bounds']")?.getBoundingClientRect().toJSON(),
      scrollX: window.scrollX
    }))
    const openedOnscreen = opened && opened.x >= 0 && opened.x + opened.width <= 390 && opened.width >= 200
    console.log(JSON.stringify({ opened, closedDetached: true, openedOnscreen, state, screenshotPath }))
    if (!openedOnscreen || state.scrollX !== 0 || state.main?.x !== 0 || state.main?.width !== 390) {
      process.exitCode = 1
    }
  } finally {
    await browser.close()
  }
})().catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
