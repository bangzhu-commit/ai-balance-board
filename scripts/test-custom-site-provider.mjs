// Execute the app's fixed extraction source against synthetic browser objects.
// No browser, server, account, or model is used by these checks.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const swift = readFileSync(new URL('../Sources/AIBalanceBoard/CustomSiteProvider.swift', import.meta.url), 'utf8');
const script = swift.match(/static let extractionScript = #"""\n([\s\S]*?)\n    """#/)[1];
const origin = 'https://relay.example.com';

async function run(overrides = {}) {
  let clock = 0;
  const path = overrides.mode === 'dom' ? '/dashboard' : '/api/balance';
  const sandbox = {
    URL, TextEncoder,
    expectedOrigin: origin, expectedPath: path, mode: 'json', selectors: [],
    location: { origin, pathname: path },
    document: { body: { textContent: '{"balance":12.5}' }, querySelectorAll() { throw new Error('unexpected DOM read'); } },
    // A second fetch would violate the one-request JSON mode and fail the test.
    fetch: () => { throw new Error('extractor must never make another request'); },
    setTimeout(fn, milliseconds) { if (milliseconds === 250) { clock += 250; fn(); } return 1; },
    clearTimeout() {}, Date: { now: () => clock },
    ...overrides,
  };
  const result = await vm.runInNewContext(`(async () => {${script}\n})()`, sandbox, { timeout: 1000 });
  return { result: JSON.parse(result), sandbox };
}

const jsonDocument = textContent => ({ body: { textContent } });

test('JSON reads the already-loaded document without a second request', async () => {
  const { result } = await run();
  assert.deepEqual(result, { kind: 'ok', body: '{"balance":12.5}' });
  assert.equal(script.includes('fetch('), false);
});

test('wrong document origin and login redirect cannot produce a reading', async () => {
  for (const location of [{ origin: 'https://other.example.com', pathname: '/api/balance' }, { origin, pathname: '/login' }]) {
    assert.equal((await run({ location })).result.kind, 'auth');
  }
});

test('JSON size checks cover both character count and UTF-8 byte size', async () => {
  assert.equal((await run({ document: jsonDocument('x'.repeat(524289)) })).result.kind, 'invalid');
  assert.equal((await run({ document: jsonDocument(JSON.stringify({ text: '中'.repeat(180000) })) })).result.kind, 'invalid');
});

test('invalid, empty and HTML documents cannot turn into a balance', async () => {
  for (const text of ['not json', '', '<html>login</html>']) {
    assert.equal((await run({ document: jsonDocument(text) })).result.kind, 'invalid');
  }
});

test('JSON formatting and unicode are preserved for the core parser', async () => {
  const body = '{\n "balance": 12.50, "unit": "元", "message": "<script>ignore</script>"\n}';
  const { result } = await run({ document: jsonDocument(body) });
  assert.equal(result.kind, 'ok');
  assert.equal(result.body, body);
});

test('JSON document root fallback is bounded too', async () => {
  assert.equal((await run({ document: { documentElement: { textContent: '{"balance":0}' } } })).result.kind, 'ok');
  assert.equal((await run({ document: {} })).result.kind, 'invalid');
});

test('DOM reads unique selectors and returns text only', async () => {
  const { result } = await run({ mode: 'dom', selectors: ['#balance', '.total'], document: {
    querySelectorAll(selector) { return [{ textContent: selector === '#balance' ? ' 1,234.50 USD ' : '2000' }]; },
  } });
  assert.deepEqual(result, { kind: 'ok', values: { '#balance': '1,234.50 USD', '.total': '2000' } });
});

test('DOM ambiguity, selector syntax and text limits fail closed', async () => {
  for (const querySelectorAll of [() => [{ textContent: '1' }, { textContent: '2' }], () => { throw new Error('syntax'); }, () => [{ textContent: 'x'.repeat(4097) }]]) {
    const { result } = await run({ mode: 'dom', selectors: ['#balance'], document: { querySelectorAll } });
    assert.equal(result.kind, 'invalid');
  }
});

test('DOM waits for missing content only until its bounded deadline', async () => {
  let reads = 0;
  const { result } = await run({ mode: 'dom', selectors: ['#balance'], document: { querySelectorAll() { reads++; return []; } } });
  assert.equal(result.kind, 'invalid');
  assert.equal(reads, 32);
});

test('selector text is treated as data, never evaluated as code', async () => {
  const selector = `#balance'); globalThis.executed = true; //`;
  const { result, sandbox } = await run({ mode: 'dom', selectors: [selector], document: { querySelectorAll(value) {
    assert.equal(value, selector);
    return [{ textContent: '42' }];
  } } });
  assert.equal(result.kind, 'ok');
  assert.equal(sandbox.executed, undefined);
});

test('DOM modes and field count are restricted', async () => {
  assert.equal((await run({ mode: 'script' })).result.kind, 'invalid');
  assert.equal((await run({ mode: 'dom', selectors: [] })).result.kind, 'invalid');
  assert.equal((await run({ mode: 'dom', selectors: Array(13).fill('#x') })).result.kind, 'invalid');
});

test('DOM redirects after load cannot be read from the new origin', async () => {
  assert.equal((await run({ mode: 'dom', selectors: ['#x'], location: { origin: 'https://login.example.com', pathname: '/dashboard' } })).result.kind, 'auth');
});
