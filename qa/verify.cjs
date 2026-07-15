const { chromium } = require('playwright')
const fs = require('node:fs/promises')
const path = require('node:path')

const URL = process.env.HERMES_DESKTOP_WEB_URL || 'http://127.0.0.1:9122/'
const OUT = process.env.HERMES_DESKTOP_WEB_QA_OUT || path.join(process.cwd(), 'qa-output')
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined

async function capture(page, name) {
  await page.screenshot({ path: path.join(OUT, `${name}.png`), fullPage: false })
}

async function waitForDesktop(page) {
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 60_000 })
  await page.waitForSelector("html[data-hermes-browser='true']", { timeout: 30_000 })
  await page.waitForSelector("[data-slot='composer-root']", { timeout: 60_000 })
  await page.waitForTimeout(1_200)
}

async function box(locator) {
  const value = await locator.boundingBox()
  if (!value) throw new Error('Expected a visible element')
  return value
}

;(async () => {
  await fs.mkdir(OUT, { recursive: true })
  const browser = await chromium.launch({ executablePath, headless: true, args: ['--no-sandbox'] })
  const errors = []
  const failures = []
  const watch = (page, name) => {
    page.on('console', message => {
      if (message.type() === 'error') errors.push(`${name} console: ${message.text()}`)
    })
    page.on('pageerror', error => errors.push(`${name} page: ${error.message}`))
    page.on('requestfailed', request => errors.push(`${name} request: ${request.url()} ${request.failure()?.errorText}`))
  }

  try {
    const desktop = await browser.newPage({ viewport: { width: 1440, height: 900 } })
    watch(desktop, 'desktop')
    await waitForDesktop(desktop)
    if ((await desktop.title()) !== 'Hermes') failures.push('Desktop title is not Hermes')
    if (!(await desktop.locator("[data-slot='composer-root']").isVisible())) failures.push('Desktop composer is hidden')
    const contract = await desktop.evaluate(async () => {
      const api = window.hermesDesktop
      const methods = [
        'getConnection',
        'getGatewayWsUrl',
        'openSessionWindow',
        'normalizePreviewTarget',
        'watchPreviewFile',
        'stopPreviewFileWatch',
        'readDir',
        'getVersion'
      ]
      const groups = ['petOverlay', 'terminal', 'updates', 'uninstall', 'themes', 'git', 'cloud']
      const version = await api.getVersion()

      return {
        groups: groups.filter(name => !api[name]),
        methods: methods.filter(name => typeof api[name] !== 'function'),
        updateSupported: (await api.updates.check()).supported,
        version
      }
    })
    if (contract.methods.length || contract.groups.length) failures.push('Browser bridge contract is incomplete')
    if (contract.updateSupported !== false) failures.push('Browser update adapter did not fail closed')
    if (!contract.version.appVersion || contract.version.platform !== 'web') failures.push('Browser version contract is invalid')

    const sessionId = 'qa / ?# ü'
    const context = desktop.context()
    const reuseCountKey = '__hermesNamedSessionLoadCount'
    await context.addInitScript(key => {
      localStorage.setItem(key, String(Number(localStorage.getItem(key) || '0') + 1))
    }, reuseCountKey)
    const expectedPageCount = context.pages().length + 1
    const sessionPagePromise = context.waitForEvent('page')
    const firstOpen = await desktop.evaluate(
      id => window.hermesDesktop.openSessionWindow(id, { watch: true }),
      sessionId
    )
    const sessionPage = await sessionPagePromise
    await sessionPage.waitForLoadState('domcontentloaded')
    const firstSessionUrl = new URL(sessionPage.url())
    const firstSessionHref = sessionPage.url()
    const firstLoadCount = await sessionPage.evaluate(key => Number(localStorage.getItem(key)), reuseCountKey)
    const openerWasCleared = await sessionPage.evaluate(() => window.opener === null)
    const secondOpen = await desktop.evaluate(
      id => window.hermesDesktop.openSessionWindow(id, { watch: true }),
      sessionId
    )
    await desktop.waitForTimeout(300)
    const secondLoadCount = await sessionPage.evaluate(key => Number(localStorage.getItem(key)), reuseCountKey)
    const openerRemainedCleared = await sessionPage.evaluate(() => window.opener === null)
    if (!firstOpen.ok || !secondOpen.ok) failures.push('Named session window did not open successfully')
    if (firstSessionUrl.pathname !== new URL(desktop.url()).pathname) failures.push('Named session mount path changed')
    if (firstSessionUrl.searchParams.get('win') !== 'secondary' || firstSessionUrl.searchParams.get('watch') !== '1') {
      failures.push('Named session window flags are invalid')
    }
    if (decodeURIComponent(firstSessionUrl.hash.slice(2)) !== sessionId) failures.push('Named session route is invalid')
    if (context.pages().length !== expectedPageCount || firstLoadCount !== 1 || secondLoadCount !== 1) {
      failures.push('Named session reuse created or reloaded a browser window')
    }
    if (sessionPage.url() !== firstSessionHref) failures.push('Named session reuse navigated the browser window')
    if (!openerWasCleared || !openerRemainedCleared) failures.push('Named session window retained an opener')
    await sessionPage.close()
    await capture(desktop, 'desktop-home')
    await desktop.close()

    const mobile = await browser.newPage({
      viewport: { width: 390, height: 844 },
      isMobile: true,
      hasTouch: true,
      deviceScaleFactor: 2
    })
    watch(mobile, 'mobile')
    await waitForDesktop(mobile)
    await capture(mobile, 'mobile-home')

    const leftToggle = mobile.getByRole('button', { name: /sidebar/i }).first()
    const settings = mobile.getByRole('button', { name: /settings/i }).first()
    const rightToggle = mobile.getByRole('button', { name: /right sidebar/i }).first()
    for (const [name, locator] of [
      ['left navigation', leftToggle],
      ['settings', settings],
      ['right navigation', rightToggle]
    ]) {
      const rect = await box(locator)
      if (rect.width < 44 || rect.height < 44) failures.push(`${name} target is smaller than 44px`)
    }

    await leftToggle.click()
    const sidebar = mobile.locator("[data-pane-id='chat-sidebar'][data-forced]")
    await sidebar.waitFor({ state: 'attached', timeout: 5_000 })
    await mobile.waitForTimeout(300)
    const sidebarBox = await box(sidebar.locator(':scope > div:last-child'))
    if (sidebarBox.width < 300 || sidebarBox.width >= 390) failures.push('Mobile sidebar width is outside the expected overlay range')
    await capture(mobile, 'mobile-sidebar')
    await mobile.getByRole('button', { name: 'Close chat-sidebar' }).click({ position: { x: 380, y: 420 } })
    await mobile.waitForTimeout(350)

    const editor = mobile.locator("[contenteditable='true'][role='textbox']").first()
    await editor.click()
    await editor.fill('line one')
    await editor.press('Enter')
    await editor.type('line two')
    const editorText = await editor.innerText()
    if (!editorText.includes('\n') || !editorText.includes('line two')) failures.push('Touch Enter did not insert a newline')
    await capture(mobile, 'mobile-composer-multiline')

    const send = mobile.getByRole('button', { name: /^Send$/i })
    const sendBox = await box(send)
    if (sendBox.width < 44 || sendBox.height < 44) failures.push('Send target is smaller than 44px')

    await settings.click()
    const overlay = mobile.locator("[data-slot='overlay-card']")
    await overlay.waitFor({ state: 'visible', timeout: 5_000 })
    const overlayBox = await box(overlay)
    if (overlayBox.x < 0 || overlayBox.y < 0 || overlayBox.x + overlayBox.width > 390 || overlayBox.y + overlayBox.height > 844) {
      failures.push('Settings overlay exceeds the mobile viewport')
    }
    await capture(mobile, 'mobile-settings')
    await mobile.keyboard.press('Escape')
    await overlay.waitFor({ state: 'hidden', timeout: 5_000 })

    const layout = await mobile.evaluate(() => ({
      horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      main: document.querySelector('[data-pane-main]')?.getBoundingClientRect().toJSON(),
      scrollX: window.scrollX,
      statusbarVisible: Boolean(document.querySelector("[data-slot='statusbar']")?.getClientRects().length)
    }))
    if (layout.horizontalOverflow || layout.scrollX !== 0 || layout.main?.x !== 0 || layout.main?.width !== 390) {
      failures.push('Mobile layout shifted or overflowed horizontally')
    }
    if (layout.statusbarVisible) failures.push('Desktop status bar is visible on mobile')

    const report = { url: mobile.url(), layout, sidebarWidth: sidebarBox.width, sendBox, errors, failures }
    console.log(JSON.stringify(report, null, 2))
    if (errors.length || failures.length) process.exitCode = 1
  } finally {
    await browser.close()
  }
})().catch(error => {
  console.error(error.stack || error)
  process.exit(1)
})
