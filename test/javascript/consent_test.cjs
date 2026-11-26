// Run with: node --test test/javascript/consent_test.cjs
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('priv/static/assets/phoenix_kit_consent.js', 'utf8');
const settle = () => new Promise(resolve => setImmediate(resolve));
const decision = analytics => ({
  necessary: true, analytics, marketing: false, preferences: false,
  timestamp: new Date().toISOString()
});
const response = body => ({ok: true, status: 200, json: async () => body});

function fixture(stored = null, pending = false) {
  const data = new Map(stored ? [
    ['pk_consent', JSON.stringify(stored)], ['pk_consent_version', '1.0']
  ] : []);
  if (pending) data.set('pk_consent_revoke_pending', String(Date.now()));
  const storage = values => ({
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: key => values.delete(key)
  });
  const elements = new Map();
  for (const id of ['root', 'banner', 'icon', 'modal']) {
    elements.set('pk-consent-' + id, {
      style: {}, classList: { remove() {} }, setAttribute() {},
      dataset: {
        frameworks: '["gdpr"]', consentMode: 'strict', policyVersion: '1.0',
        consentEndpoint: '/consent', googleConsentMode: 'true',
        reloadOnWithdrawal: 'false'
      }
    });
  }
  const listeners = new Map();
  const events = [];
  const requests = [];
  let reloads = 0;
  const on = (name, fn) => {
    if (!listeners.has(name)) listeners.set(name, []);
    listeners.get(name).push(fn);
  };
  const context = {
    console: { debug() {} }, Date, Promise, setTimeout,
    localStorage: storage(data), sessionStorage: storage(new Map()),
    document: {
      readyState: 'complete', getElementById: id => elements.get(id),
      querySelectorAll: () => [], addEventListener: on
    },
    addEventListener: on, dispatchEvent: event => events.push(event),
    CustomEvent: function(type, options) { this.type = type; this.detail = options.detail; },
    location: { reload() { reloads++; } },
    fetch: (url, options) => new Promise(resolve => requests.push({url, ...options, resolve}))
  };
  context.window = context;
  vm.runInNewContext(source, context);
  return {
    context, data, requests, events, listeners, elements,
    consent: context.PhoenixKitConsent,
    emit: (name, event) => (listeners.get(name) || []).forEach(fn => fn(event)),
    reloads: () => reloads
  };
}

test('revoking immediately denies Google and page listeners without a reload', () => {
  const f = fixture(decision(true));
  f.consent.revokeConsent();
  const update = f.context.dataLayer.filter(args => args[1] === 'update').at(-1);
  assert.equal(update[2].analytics_storage, 'denied');
  assert.equal(f.events.at(-1).detail.consent.analytics, false);
  assert.equal(f.consent.getConsent(), null);
});

test('a pending reconciliation cannot restore grants after a new refusal', async () => {
  const f = fixture(decision(true));
  const get = f.requests[0];
  f.consent.rejectAll();
  get.resolve(response({decided: true, version: '1.0',
    decided_at: Math.floor(Date.now() / 1000) + 60, consent: {analytics: true, marketing: true}}));
  await settle();
  assert.equal(f.consent.getConsent().analytics, false);
  assert.equal(JSON.parse(f.data.get('pk_consent')).analytics, false);
});

test('a pending reconciliation cannot re-post grants after revocation', async () => {
  const f = fixture(decision(true));
  const get = f.requests[0];
  f.consent.revokeConsent();
  get.resolve(response({decided: false}));
  await settle();
  assert.equal(f.requests.filter(r => r.method === 'POST').length, 0);
});

test('rapid decisions reach the server in order', async () => {
  const f = fixture();
  f.consent.acceptAll();
  f.consent.rejectAll();
  await settle();
  assert.equal(f.requests.length, 1);
  assert.equal(JSON.parse(f.requests[0].body).consent.analytics, true);
  f.requests[0].resolve(response({}));
  await settle();
  assert.equal(f.requests.length, 2);
  assert.equal(JSON.parse(f.requests[1].body).consent.analytics, false);
});

test('a pending revocation check cannot delete a subsequent decision', async () => {
  const f = fixture(null, true);
  const get = f.requests[0];
  f.consent.acceptAll();
  get.resolve(response({decided: true, decided_at: Math.floor(Date.now() / 1000) - 10}));
  await settle();
  assert.equal(f.requests.filter(r => r.method === 'DELETE').length, 0);
});

test('LiveView hook remounts register each global listener once', () => {
  const f = fixture();
  const hook = f.context.PhoenixKitHooks.CookieConsent;
  hook.destroyed();
  hook.mounted.call({el: f.elements.get('pk-consent-root')});
  assert.equal(f.listeners.get('storage').length, 1);
  assert.equal(f.listeners.get('keydown').length, 1);
});

test('withdrawal in another tab reloads when configured', () => {
  const f = fixture(decision(true));
  f.consent.config.reloadOnWithdrawal = true;
  f.data.delete('pk_consent');
  f.emit('storage', {key: 'pk_consent', newValue: null});
  assert.equal(f.reloads(), 1);
  assert.equal(f.consent.getConsent(), null);
});

test('clock skew cannot overwrite an undelivered refusal with server grants', async () => {
  const refused = decision(false);
  refused.timestamp = new Date(Date.now() - 3600000).toISOString();
  refused.pending = true;
  const f = fixture(refused);
  f.requests[0].resolve(response({decided: true, version: '1.0',
    decided_at: Math.floor(Date.now() / 1000), consent: {analytics: true}}));
  await settle();
  assert.equal(f.consent.getConsent().analytics, false);
  assert.equal(f.requests[1].method, 'POST');
  assert.equal(JSON.parse(f.requests[1].body).consent.analytics, false);
  f.requests[1].resolve(response({}));
  await settle();
  assert.equal(JSON.parse(f.data.get('pk_consent')).pending, undefined);
});

test('blocked storage cannot prevent server withdrawal', async () => {
  const f = fixture(decision(true));
  f.context.localStorage.removeItem = () => { throw new Error('storage blocked'); };
  f.consent.revokeConsent();
  await settle();
  assert.equal(f.requests.filter(r => r.method === 'DELETE').length, 1);
  assert.equal(f.consent.getConsent(), null);
});

test('a failed write does not prevent the next queued decision', async () => {
  const f = fixture();
  f.consent.acceptAll();
  f.consent.rejectAll();
  await settle();
  f.requests[0].resolve({ok: false, status: 503});
  await settle();
  assert.equal(f.requests.length, 2);
  assert.equal(JSON.parse(f.requests[1].body).consent.analytics, false);
});

test('an acknowledged server decision can still replace an older browser copy', async () => {
  const f = fixture(decision(false));
  f.requests[0].resolve(response({decided: true, version: '1.0',
    decided_at: Math.floor(Date.now() / 1000) + 60, consent: {analytics: true}}));
  await settle();
  assert.equal(f.consent.getConsent().analytics, true);
  assert.equal(f.requests.length, 1);
});

test('successful reconciliation stays capped when the browser refuses cookies', async () => {
  const f = fixture(decision(true));
  f.requests[0].resolve(response({decided: false}));
  await settle();
  assert.equal(f.requests[1].method, 'POST');
  f.requests[1].resolve(response({}));
  await settle();
  const hook = f.context.PhoenixKitHooks.CookieConsent;
  hook.destroyed();
  hook.mounted.call({el: f.elements.get('pk-consent-root')});
  await settle();
  assert.equal(f.requests.length, 2);
});

test('a remounted hook drops expired in-memory grants', () => {
  const f = fixture(decision(true));
  const expired = decision(true);
  expired.timestamp = new Date(Date.now() - 181 * 86400000).toISOString();
  f.data.set('pk_consent', JSON.stringify(expired));
  const hook = f.context.PhoenixKitHooks.CookieConsent;
  hook.destroyed();
  hook.mounted.call({el: f.elements.get('pk-consent-root')});
  assert.equal(f.consent.getConsent(), null);
  const update = f.context.dataLayer.filter(args => args[1] === 'update').at(-1);
  assert.equal(update[2].analytics_storage, 'denied');
});

// ---------------------------------------------------------------------------
// Content-Security-Policy: no inline handler, a nonce on what the script creates
// ---------------------------------------------------------------------------

const click = action => ({
  target: {
    closest: selector => selector === '[data-pkl-consent]'
      ? { getAttribute: () => action }
      : null
  }
});

test('a button that names its action is answered by one document listener', () => {
  const f = fixture();
  assert.equal(f.listeners.get('click').length, 1);

  f.emit('click', click('acceptAll'));
  assert.equal(f.consent.getConsent().analytics, true);

  f.emit('click', click('rejectAll'));
  assert.equal(f.consent.getConsent().analytics, false);
});

test('a click names only the five widget actions, and a click elsewhere is ignored', () => {
  const f = fixture(decision(true));
  f.emit('click', click('revokeConsent'));
  f.emit('click', click('constructor'));
  f.emit('click', { target: { closest: () => null } });
  f.emit('click', { target: {} });
  assert.equal(f.consent.getConsent().analytics, true);
});

test('a released script keeps the nonce of the tag it replaces', () => {
  const f = fixture();
  const created = [];
  let replaced = null;
  const blocked = {
    // What a browser shows under a policy: the attribute emptied, the value on the property.
    attributes: [
      { name: 'type', value: 'text/plain' }, { name: 'data-blocked', value: 'true' },
      { name: 'nonce', value: '' }, { name: 'data-consent-category', value: 'analytics' }
    ],
    nonce: 'page-nonce', src: '', textContent: 'track()',
    parentNode: { replaceChild: (fresh) => { replaced = fresh; } }
  };
  f.context.document.querySelectorAll = selector =>
    selector.includes('"analytics"') ? [blocked] : [];
  f.context.document.createElement = tag => {
    const el = { tag, attrs: {}, setAttribute(name, value) { this.attrs[name] = value; } };
    created.push(el);
    return el;
  };

  f.consent.acceptAll();

  assert.equal(replaced.tag, 'script');
  assert.equal(replaced.nonce, 'page-nonce');
  assert.equal('nonce' in replaced.attrs, false);
  assert.equal(replaced.attrs['data-consent-category'], 'analytics');
  assert.equal(replaced.textContent, 'track()');
});

async function injected(f) {
  const appended = [];
  const styles = [];
  let html = null;
  f.context.document.createElement = tag => {
    if (tag === 'style') {
      const style = { tag };
      styles.push(style);
      return style;
    }
    const root = { children: [], firstChild: null, insertBefore(el) { this.children.unshift(el); } };
    return { set innerHTML(value) { html = value; }, firstChild: root };
  };
  f.context.document.body = { appendChild: el => appended.push(el) };
  f.elements.delete('pk-consent-root');
  f.context.PhoenixKitHooks.CookieConsent.destroyed();
  f.consent.init();
  f.requests.at(-1).resolve(response({ enabled: true, frameworks: ['gdpr'] }));
  await settle();
  await settle();
  return { appended, styles, html };
}

test('the injected widget carries no inline handler and no <style> in its HTML', async () => {
  const f = fixture();
  const { appended, styles, html } = await injected(f);

  assert.equal(appended.length, 1);
  assert.doesNotMatch(html, /\son[a-z]+=/);
  assert.doesNotMatch(html, /<style/);
  assert.equal((html.match(/data-pkl-consent="/g) || []).length, 8);
  assert.equal(styles.length, 1);
  assert.equal(appended[0].children[0], styles[0]);
  assert.match(styles[0].textContent, /\.pk-consent-widget\{/);
  assert.equal(styles[0].nonce, undefined);
});

test("the injected widget's <style> is stamped by core's bundle when it is there", async () => {
  const f = fixture();
  f.context.PhoenixKitInternals = { adoptStyle: el => { el.nonce = 'from-core'; return el; } };
  const { styles } = await injected(f);
  assert.equal(styles[0].nonce, 'from-core');
});

test("without core's bundle the <style> takes the nonce of a style already on the page", async () => {
  const f = fixture();
  f.context.document.getElementsByTagName = () => [{ nonce: '' }, { nonce: 'from-page' }];
  const { styles } = await injected(f);
  assert.equal(styles[0].nonce, 'from-page');
});
