const { chromium } = require('playwright')

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
    await page.getByRole('button', { name: 'Show right sidebar' }).click()
    const pane = page.locator("[data-pane-id='file-browser']")
    await pane.waitFor({ state: 'attached' })
    await page.waitForTimeout(300)
    const opened = await pane.locator(':scope > div:last-child').boundingBox()
    await page.getByRole('button', { name: 'Close file-browser' }).click({ position: { x: 4, y: 420 } })
    await page.waitForTimeout(350)
    const closed = await pane.locator(':scope > div:last-child').boundingBox()
    const state = await pane.evaluate(element => ({
      forced: element.hasAttribute('data-forced'),
      main: document.querySelector('[data-pane-main]')?.getBoundingClientRect().toJSON(),
      pointerEvents: getComputedStyle(element.lastElementChild).pointerEvents,
      scrollX: window.scrollX
    }))
    const openedOnscreen = opened && opened.x < 390 && opened.x + opened.width > 0
    const closedOffscreen = closed && (closed.x + closed.width <= 0 || closed.x >= 390)
    console.log(JSON.stringify({ opened, closed, openedOnscreen, closedOffscreen, state }))
    if (!openedOnscreen || !closedOffscreen || state.forced || state.scrollX !== 0 || state.main?.x !== 0) {
      process.exitCode = 1
    }
  } finally {
    await browser.close()
  }
})().catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
