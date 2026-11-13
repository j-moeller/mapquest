// Renders an HTML page to a PNG with Chromium (Playwright): node shoot.js <html> <png> [width height scale]
const { chromium } = require('playwright');
(async () => {
  const [html, png, w = '430', h = '932', scale = '3'] = process.argv.slice(2);
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: +scale });
  await page.goto('file://' + html, { waitUntil: 'load', timeout: 180000 });
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(300);
  await page.screenshot({ path: png, timeout: 180000 });
  await browser.close();
})().catch(e => { console.error(e); process.exit(1); });
