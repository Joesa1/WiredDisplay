const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

(async () => {
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  let stateRequests = 0;
  let commands = [];
  let authorized = true;
  const apps = Array.from({ length: 210 }, (_, index) => ({
    id: `app${index}`, name: `Application ${index}`, icon: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Jd0UAAAAASUVORK5CYII=', running: index < 2, active: index === 0
  }));
  const state = {
    host: 'Test Mac', appsRevision: 1, apps,
    music: { available: true, title: 'Test Track', artist: 'Artist', album: 'Album', playing: true },
    agents: { items: [{ name: 'Codex', status: 'working', detail: 'Local task' }] },
    weather: { city: 'Test City', temperature: 22, high: 24, low: 15, description: '晴' },
    controls: { volumeAvailable: true, volume: 42, brightnessAvailable: false }
  };
  const html = fs.readFileSync(path.join(__dirname, '../Resources/touch-bar.html'), 'utf8');
  await page.route('http://touch.test/**', async route => {
    const url = new URL(route.request().url());
    if (url.pathname === '/api/pair') return route.fulfill({ json: { token: 'test-token' } });
    if (url.pathname === '/api/state') {
      stateRequests += 1;
      if (!authorized) return route.fulfill({ status: 401, json: { message: 'Unauthorized' } });
      return route.fulfill({ json: stateRequests === 1 ? state : { ...state, apps: undefined, appStates: apps.map((app, index) => ({ id: app.id, running: app.running, active: index === 1 })) } });
    }
    if (url.pathname === '/api/command') { commands.push(route.request().postDataJSON()); return route.fulfill({ json: { ok: true, message: 'Command accepted' } }); }
    if (url.pathname.startsWith('/assets/')) return route.fulfill({ status: 204 });
    return route.fulfill({ contentType: 'text/html', body: html });
  });
  await page.goto('http://touch.test/');
  await page.fill('#code', '123456');
  await page.click('#pair-form button');
  await page.waitForSelector('#pair', { state: 'hidden' });
  assert.equal(await page.locator('#title').textContent(), 'Test Track');
  assert(await page.locator('#bright').isDisabled());
  assert.equal(await page.locator('#apps img').count(), 210);
  await page.click('#play');
  await page.waitForFunction(() => document.querySelectorAll('#apps img').length === 210);
  assert.equal(commands[0].action, 'music.playPause');
  await page.click('#open-apps');
  await page.click('#search-toggle');
  await page.fill('#query', 'Application 209');
  assert.equal(await page.locator('#grid button').count(), 1);
  await page.click('#close');
  for (const [width, height] of [[844, 390], [667, 375], [568, 320]]) {
    await page.setViewportSize({ width, height });
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  }
  authorized = false;
  await page.click('#play');
  await page.waitForSelector('#pair:not([hidden])');
  assert.deepEqual(errors, []);
  assert(stateRequests >= 3);
  await browser.close();
  console.log('Touch Bar v4 browser checks passed.');
})().catch(error => { console.error(error); process.exit(1); });
