// Requires Playwright and its Chromium installation. Run from the repo root:
// node test/javascript/consent_browser_test.cjs
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const http = require('node:http');

const config = {
  enabled: true, frameworks: ['gdpr'], consent_mode: 'strict', policy_version: '1.0',
  consent_endpoint: '/phoenix_kit/api/consent', google_consent_mode: true,
  reload_on_withdrawal: false, purposes: {analytics: ['Visit statistics']}
};
const writes = [];
// A host without a consent component, loading core's actual old manager first.
// The endpoint is a browser fixture; the ExUnit suite tests signed cookies/DDL.
const server = http.createServer(async (req, res) => {
  if (req.url === '/core.js' || req.url === '/legal.js') {
    res.setHeader('content-type', 'application/javascript');
    return res.end(fs.readFileSync(req.url === '/core.js'
      ? 'deps/phoenix_kit/priv/static/assets/phoenix_kit.js'
      : 'priv/static/assets/phoenix_kit_consent.js'));
  }
  if (req.url === '/phoenix_kit/api/consent-config') {
    res.setHeader('content-type', 'application/json');
    return res.end(JSON.stringify(config));
  }
  if (req.url === '/phoenix_kit/api/consent') {
    res.setHeader('content-type', 'application/json');
    res.setHeader('cache-control', 'no-store');
    if (req.method === 'POST') {
      let body = '';
      for await (const part of req) body += part;
      const decision = JSON.parse(body);
      writes.push(decision);
      const consent = {decided: true, version: '1.0', consent: decision.consent,
        decided_at: Math.floor(Date.now() / 1000)};
      res.setHeader('set-cookie', 'pk_consent=' + encodeURIComponent(JSON.stringify(consent)) + '; Path=/; SameSite=Lax');
      return res.end(JSON.stringify(consent));
    }
    if (req.method === 'DELETE') {
      res.setHeader('set-cookie', 'pk_consent=; Path=/; Max-Age=0');
      return res.end('{"decided":false}');
    }
    const match = /(?:^|; )pk_consent=([^;]+)/.exec(req.headers.cookie || '');
    return res.end(match ? decodeURIComponent(match[1]) : '{"decided":false}');
  }
  res.setHeader('content-type', 'text/html');
  res.end('<!doctype html><html><body><main>Host page</main>' +
    '<script src="/core.js"></script><script>window.capturedHook = window.PhoenixKitHooks.CookieConsent;</script>' +
    '<script src="/legal.js"></script></body></html>');
});

(async () => {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const browser = await chromium.launch({headless: true, args: ['--no-sandbox']});
  try {
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const url = 'http://127.0.0.1:' + server.address().port;
    await page.goto(url);
    await page.waitForFunction(() => window.PhoenixKitConsent?.initialized);
    assert.equal(await page.locator('#pk-consent-root').count(), 1);
    assert.equal(await page.evaluate(() => capturedHook.mounted === PhoenixKitHooks.CookieConsent.mounted), true);
    await page.getByRole('button', {name: 'Accept All', exact: true}).first().click();
    await page.waitForFunction(() => !PhoenixKitConsent.getConsent()?.pending);
    assert.equal(writes.at(-1).consent.analytics, true);
    await page.evaluate(() => PhoenixKitConsent.openPreferences());
    assert.match(await page.locator('[data-covers="analytics"]').textContent(), /Visit statistics/);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#pk-consent-modal').isVisible(), false);

    const second = await context.newPage();
    await second.goto(url);
    await second.waitForFunction(() => PhoenixKitConsent.initialized && PhoenixKitConsent.hasConsent('analytics'));
    await page.evaluate(() => PhoenixKitConsent.revokeConsent());
    await second.waitForFunction(() => PhoenixKitConsent.getConsent() === null);
    await page.waitForFunction(() => !localStorage.getItem('pk_consent_revoke_pending'));
    for (const tab of [page, second]) {
      assert.equal(await tab.evaluate(() =>
        dataLayer.filter(args => args[1] === 'update').at(-1)[2].analytics_storage), 'denied');
    }
    assert.equal((await context.cookies()).some(cookie => cookie.name === 'pk_consent'), false);

    await page.evaluate(() => { PhoenixKitConsent.acceptAll(); PhoenixKitConsent.rejectAll(); });
    await page.waitForFunction(() => !PhoenixKitConsent.getConsent()?.pending);
    assert.deepEqual(writes.slice(-2).map(write => write.consent.analytics), [true, false]);
    assert.equal(await page.evaluate(async () => (await (await fetch('/phoenix_kit/api/consent')).json()).consent.analytics), false);

    await page.evaluate(() => PhoenixKitConsent.acceptAll());
    await page.waitForFunction(() => !PhoenixKitConsent.getConsent()?.pending);
    await second.waitForFunction(() => PhoenixKitConsent.hasConsent('analytics'));
    await second.evaluate(() => { PhoenixKitConsent.config.reloadOnWithdrawal = true; });
    const reloaded = second.waitForEvent('load');
    await page.evaluate(() => PhoenixKitConsent.rejectAll());
    await reloaded;
    await second.waitForFunction(() => PhoenixKitConsent.initialized && !PhoenixKitConsent.hasConsent('analytics'));
    assert.deepEqual(errors, []);
    console.log('PASS: core takeover, injected widget, preferences, Escape, cross-tab withdrawal/reload, Google denial, cookie deletion, ordered writes');
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; }).finally(() => server.close());
