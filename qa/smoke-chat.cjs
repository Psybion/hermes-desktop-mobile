const { chromium } = require('playwright')
const fs = require('node:fs/promises')
const path = require('node:path')

const URL = process.env.HERMES_DESKTOP_WEB_URL || 'http://127.0.0.1:9122/'
const OUT = process.env.HERMES_DESKTOP_WEB_QA_OUT || path.join(process.cwd(), 'qa-output')
const SCREENSHOT = path.join(OUT, 'mobile-chat-smoke.png')
const PROMPT = process.env.HERMES_DESKTOP_WEB_SMOKE_PROMPT || 'Reply with exactly: HERMES_DESKTOP_WEB_OK'
const EXPECTED = process.env.HERMES_DESKTOP_WEB_SMOKE_EXPECTED || 'HERMES_DESKTOP_WEB_OK'
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined

;(async () => {
  await fs.mkdir(OUT, { recursive: true })
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] })
  const page = await browser.newPage({
    viewport: { width: 390, height: 844 },
    isMobile: true,
    hasTouch: true,
    deviceScaleFactor: 2
  })
  const errors = []
  page.on('console', message => {
    if (message.type() === 'error') errors.push(`console: ${message.text()}`)
  })
  page.on('pageerror', error => errors.push(`page: ${error.message}`))

  try {
    await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60_000 })
    await page.waitForSelector("[data-slot='composer-root']", { timeout: 60_000 })
    const editor = page.locator("[contenteditable='true'][role='textbox']").first()
    await editor.fill(PROMPT)
    await page.getByRole('button', { name: /^Send$/i }).click()
    await page.getByText(EXPECTED, { exact: true }).last().waitFor({ state: 'visible', timeout: 120_000 })
    await page.waitForTimeout(500)

    for (const paneId of ['chat-sidebar', 'review', 'file-browser']) {
      const forcedPane = page.locator(`[data-pane-id='${paneId}'][data-forced]`)
      if ((await forcedPane.count()) > 0) {
        await page.getByRole('button', { name: `Close ${paneId}` }).click({ position: { x: 4, y: 420 } })
        await page.waitForTimeout(350)
      }
    }

    const promptBox = await page.getByText(PROMPT, { exact: true }).last().boundingBox()
    const responseBox = await page.getByText(EXPECTED, { exact: true }).last().boundingBox()
    const composerBox = await page.locator("[data-slot='composer-root']").boundingBox()
    const layout = await page.evaluate(() => ({
      horizontalOverflow: document.documentElement.scrollWidth > window.innerWidth,
      main: document.querySelector('[data-pane-main]')?.getBoundingClientRect().toJSON(),
      scrollX: window.scrollX
    }))
    const onScreen = box => box && box.x >= 0 && box.x < 390 && box.x + box.width <= 390
    const layoutOk =
      onScreen(promptBox) &&
      onScreen(responseBox) &&
      onScreen(composerBox) &&
      layout.main?.x === 0 &&
      layout.main?.width === 390 &&
      layout.scrollX === 0 &&
      !layout.horizontalOverflow
    await page.screenshot({ path: SCREENSHOT, fullPage: false })
    console.log(JSON.stringify({ expected: EXPECTED, promptBox, responseBox, composerBox, layout, layoutOk, errors }))
    if (errors.length || !layoutOk) process.exitCode = 1
  } finally {
    await browser.close()
  }
})().catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
