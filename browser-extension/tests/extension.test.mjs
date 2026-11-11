import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFile } from "node:fs/promises";
import { createHash, webcrypto } from "node:crypto";

const root = new URL("../", import.meta.url);
const files = Object.fromEntries(await Promise.all(
  ["manifest.json", "protocol.js", "content.js", "background.js", "popup.js"].map(async name =>
    [name, await readFile(new URL(name, root), "utf8")])
));
const ID = "eghfefbgledejemklpphhpcfknmpbllf";
const A = "00000000-0000-4000-8000-000000000001";
const B = "00000000-0000-4000-8000-000000000002";
const G = "00000000-0000-4000-8000-000000000003";
const H = "00000000-0000-4000-8000-000000000004";
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let i = 0; i < 4; ++i) await new Promise(setImmediate); };
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function event() {
  const listeners = [];
  return { listeners, addListener: listener => listeners.push(listener), emit: (...args) => listeners.map(fn => fn(...args)) };
}
function fakeClock() {
  let now = 0, next = 0;
  const timers = new Map();
  return {
    setTimeout(fn, ms) { const id = ++next; timers.set(id, { at: now + ms, fn }); return id; },
    clearTimeout(id) { timers.delete(id); },
    async advance(ms) {
      const end = now + ms;
      while (true) {
        const entry = [...timers].filter(([, value]) => value.at <= end).sort((a, b) => a[1].at - b[1].at)[0];
        if (!entry) break;
        now = entry[1].at; timers.delete(entry[0]); entry[1].fn(); await flush();
      }
      now = end; await flush();
    }
  };
}
function globals(clock) {
  return {
    URL, TextDecoder, Uint8Array, AbortController, crypto: webcrypto,
    setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout
  };
}
function contentHarness(fetcher, href = "https://cursor.com/dashboard/usage") {
  const clock = fakeClock();
  const onMessage = event();
  const announcements = [];
  const location = { href };
  const chrome = { runtime: {
    id: ID, onMessage, sendMessage: async message => { announcements.push(plain(message)); }
  } };
  const context = vm.createContext({ ...globals(clock), chrome, location, fetch: fetcher, addEventListener() {} });
  vm.runInContext(files["protocol.js"], context);
  vm.runInContext(files["content.js"], context);
  function send(message, sender = { id: ID }) {
    return new Promise(resolve => {
      const asynchronous = onMessage.listeners[0](message, sender, result => resolve(plain(result)));
      if (!asynchronous) resolve(undefined);
    });
  }
  return { clock, send, announcements, location };
}
const quotaQuery = (id = A, generation = G) => ({ type: "quota.query", version: 1, id, generation });
function jsonResponse(value, options = {}) {
  return new Response(JSON.stringify(value), { headers: { "Content-Type": "application/json" }, ...options });
}
function storageArea(initial = {}) {
  const data = { ...initial };
  return {
    data,
    async get(keys) {
      const list = typeof keys === "string" ? [keys] : keys;
      return Object.fromEntries(list.filter(key => key in data).map(key => [key, data[key]]));
    },
    async set(values) { Object.assign(data, plain(values)); }
  };
}
function workerHarness({ session = {}, windows = [{ id: 1, type: "normal", incognito: false }], autoReady = true } = {}) {
  const clock = fakeClock();
  const ports = [];
  const tabCalls = [];
  const createCalls = [];
  const tabs = new Map();
  const alarms = new Map();
  let nextTab = 100;
  const chrome = {
    runtime: {
      id: ID, onMessage: event(), onStartup: event(), onInstalled: event(),
      getURL: path => `chrome-extension://${ID}/${path}`,
      connectNative(name) {
        assert.equal(name, "local.outlier.ai_balance_board");
        const port = {
          sent: [], onMessage: event(), onDisconnect: event(),
          postMessage(message) { this.sent.push(plain(message)); },
          disconnect() { this.onDisconnect.emit(); }
        };
        ports.push(port); return port;
      }
    },
    storage: { local: storageArea(), session: storageArea(session) },
    alarms: {
      onAlarm: event(), async get(name) { return alarms.get(name); },
      async create(name, options) { alarms.set(name, plain(options)); },
      async clear(name) { alarms.delete(name); }
    },
    windows: { async getAll(options) { assert.deepEqual(plain(options), { windowTypes: ["normal"] }); return windows; } },
    tabs: {
      onRemoved: event(),
      async get(id) {
        if (!tabs.has(id)) throw new Error("No tab");
        return { id, get url() { throw new Error("Must not read tab URL"); } };
      },
      async sendMessage(id, message, options) {
        tabCalls.push({ id, message: plain(message), options: plain(options) });
        if (!tabs.has(id)) throw new Error("No receiver");
        return tabs.get(id)(message);
      },
      async create(options) {
        createCalls.push(plain(options));
        const id = ++nextTab;
        tabs.set(id, defaultTab);
        if (autoReady) queueMicrotask(() => readyTab(id));
        return { id, get url() { throw new Error("Must not read tab URL"); } };
      }
    }
  };
  function defaultTab(message) {
    if (message.type === "quota.ping") return { type: "quota.pong", version: 1, available: true };
    if (message.type === "quota.query") return { kind: "ok", data: { usagePercent: 42 } };
  }
  function readyTab(id, overrides = {}) {
    chrome.runtime.onMessage.emit({ type: "quota.ready", version: 1 }, {
      id: ID, frameId: 0, url: "https://cursor.com/dashboard/usage", tab: { id }, ...overrides
    }, () => {});
  }
  const context = vm.createContext({ ...globals(clock), chrome });
  context.importScripts = name => vm.runInContext(files[name], context);
  vm.runInContext(files["background.js"], context);
  function native(message, index = ports.length - 1) { ports[index].onMessage.emit(message); }
  function handshake(generation = G) { native({ type: "ready", version: 1, generation }); }
  function query(id = A, generation = G) { native({ type: "query", version: 1, id, generation }); }
  function results(index = ports.length - 1) { return ports[index].sent.filter(message => message.type === "result"); }
  return { clock, chrome, ports, tabs, tabCalls, createCalls, alarms, readyTab, defaultTab, native, handshake, query, results };
}

test("manifest has only the required permissions and the stable approved extension ID", () => {
  const manifest = JSON.parse(files["manifest.json"]);
  assert.deepEqual(manifest.permissions, ["nativeMessaging", "storage", "alarms"]);
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.externally_connectable, undefined);
  assert.equal(manifest.incognito, "not_allowed");
  assert.deepEqual(manifest.content_scripts[0].matches, ["https://cursor.com/dashboard*"]);
  assert.equal(manifest.content_scripts[0].all_frames, false);
  assert.equal(manifest.content_scripts[0].world, "ISOLATED");
  const hex = createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32);
  const id = [...hex].map(c => String.fromCharCode(97 + parseInt(c, 16))).join("");
  assert.equal(id, ID);
});

test("content script makes exactly the fixed same-origin request and drops unknown fields", async () => {
  const requests = [];
  const h = contentHarness(async (url, options) => {
    requests.push({ url, options });
    return jsonResponse({ usagePercent: 25, isUnified: false, privateField: "must not cross bridge" });
  });
  assert.deepEqual(await h.send(quotaQuery()), { kind: "ok", data: { usagePercent: 25, isUnified: false } });
  assert.equal(requests.length, 1);
  const { url, options } = requests[0];
  assert.equal(url, "/api/dashboard/get-sand-usage-status");
  assert.deepEqual(plain({ ...options, signal: undefined }), {
    method: "POST", mode: "same-origin", credentials: "same-origin", redirect: "error", cache: "no-store",
    headers: { "Content-Type": "application/json" }, body: "{}"
  });
});

test("content script rejects lookalike paths, origins and foreign extension senders", async () => {
  for (const href of ["https://cursor.com/dashboard-evil", "https://other.test/dashboard", "http://cursor.com/dashboard"]) {
    let count = 0;
    const h = contentHarness(async () => { ++count; return jsonResponse({ usagePercent: 1 }); }, href);
    assert.deepEqual(await h.send(quotaQuery()), { kind: "pageUnavailable" });
    assert.equal(count, 0); assert.equal(h.announcements.length, 0);
  }
  const h = contentHarness(() => { throw new Error("Should not fetch"); });
  assert.equal(await h.send(quotaQuery(), { id: "another-extension" }), undefined);
});

test("unknown/malformed response does not become zero; absent and null fields remain unknown", async () => {
  for (const body of [{ mystery: 2 }, [], null, { usagePercent: {} }, { usagePercent: "NaN" },
    { usagePercent: "0x10" }, { usagePercent: " 24 " }, { usagePercent: "01" }, { isTeamSeat: "false" }]) {
    const h = contentHarness(async () => jsonResponse(body));
    assert.deepEqual(await h.send(quotaQuery()), { kind: "httpError" });
  }
  const missing = contentHarness(async () => jsonResponse({ isUnified: true }));
  assert.deepEqual(await missing.send(quotaQuery()), { kind: "ok", data: { isUnified: true } });
  const explicitNull = contentHarness(async () => jsonResponse({ usagePercent: null }));
  assert.deepEqual(await explicitNull.send(quotaQuery()), { kind: "ok", data: { usagePercent: null } });
  for (const usagePercent of [110.5, "110.5", "1.105e2"]) {
    const exceeded = contentHarness(async () => jsonResponse({ usagePercent }));
    assert.deepEqual(await exceeded.send(quotaQuery()), { kind: "ok", data: { usagePercent } });
  }
});

test("content script recognizes login/rate limits and caps body size before parsing", async () => {
  for (const [status, kind] of [[401, "loginRequired"], [403, "loginRequired"], [429, "rateLimited"], [503, "httpError"]]) {
    const h = contentHarness(async () => jsonResponse({}, { status }));
    assert.deepEqual(await h.send(quotaQuery()), { kind });
  }
  const html = contentHarness(async () => new Response("<html>login</html>", { headers: { "Content-Type": "text/html" } }));
  assert.deepEqual(await html.send(quotaQuery()), { kind: "loginRequired" });
  const big = contentHarness(async () => jsonResponse({ usagePercent: 10, ignored: "x".repeat(65_536) }));
  assert.deepEqual(await big.send(quotaQuery()), { kind: "httpError" });
});

test("content script shares a duplicate request and enforces the 15-second abort", async () => {
  const response = deferred(); let count = 0;
  const h = contentHarness(() => { ++count; return response.promise; });
  const first = h.send(quotaQuery()); const duplicate = h.send(quotaQuery());
  assert.deepEqual(await h.send(quotaQuery(B)), { kind: "pageUnavailable" });
  assert.equal(count, 1);
  response.resolve(jsonResponse({ usagePercent: 24 }));
  assert.deepEqual(await first, await duplicate);
  const timeout = contentHarness((url, options) => new Promise((resolve, reject) => {
    options.signal.addEventListener("abort", () => reject(new Error("aborted")));
  }));
  const pending = timeout.send(quotaQuery());
  await timeout.clock.advance(15_000);
  assert.deepEqual(await pending, { kind: "timeout" });
});

test("native hello has stable clientID; reconnect alarm never polls quota", async () => {
  const h = workerHarness(); await flush();
  assert.equal(h.ports.length, 1);
  const hello = h.ports[0].sent[0];
  assert.equal(hello.type, "hello"); assert.equal(hello.version, 1);
  assert.equal(hello.clientID, h.chrome.storage.local.data.clientID);
  assert.equal(h.tabCalls.length, 0); assert.equal(h.createCalls.length, 0);
  h.handshake();
  h.chrome.alarms.onAlarm.emit({ name: "native-reconnect" }); await flush();
  assert.equal(h.ports.length, 1); assert.equal(h.tabCalls.length, 0);
  h.ports[0].disconnect(); await flush();
  assert.deepEqual(h.alarms.get("native-reconnect"), { delayInMinutes: 1, periodInMinutes: 1 });
  h.chrome.alarms.onAlarm.emit({ name: "native-reconnect" }); await flush();
  assert.equal(h.ports.length, 2);
  assert.equal(h.ports[1].sent[0].clientID, hello.clientID);
  h.handshake(); await flush();
  assert.equal(h.alarms.size, 0); assert.equal(h.tabCalls.length, 0); assert.equal(h.createCalls.length, 0);
});

test("worker validates ready sender and reuses only a verified dashboard tab", async () => {
  const h = workerHarness(); await flush();
  h.tabs.set(7, h.defaultTab);
  h.readyTab(7);
  h.readyTab(8, { url: "https://cursor.com/dashboard-evil" });
  h.readyTab(9, { frameId: 1 }); h.readyTab(10, { id: "foreign" });
  h.handshake(); h.query(); await flush();
  assert.equal(h.createCalls.length, 0);
  assert.equal(h.tabCalls.every(call => call.id === 7), true);
  assert.deepEqual(h.tabCalls.filter(call => call.message.type === "quota.query").map(call => call.id), [7]);
  assert.deepEqual(h.results()[0], { type: "result", version: 1, id: A, generation: G, kind: "ok", data: { usagePercent: 42 } });
});

test("worker restores tab IDs and verifies by ping without reading tab URLs", async () => {
  const h = workerHarness({ session: { quotaTabIds: [5], ownedTabId: 5 } });
  h.tabs.set(5, h.defaultTab); await flush(); h.handshake(); h.query(); await flush();
  assert.equal(h.createCalls.length, 0);
  assert.equal(h.results()[0].kind, "ok");
  assert.equal(h.tabCalls[0].message.type, "quota.ping");
});

test("worker creates at most one inactive tab in an existing window, then reuses it", async () => {
  const h = workerHarness(); await flush(); h.handshake(); h.query(); await flush();
  assert.deepEqual(h.createCalls, [{ windowId: 1, active: false, url: "https://cursor.com/dashboard" }]);
  assert.equal(h.results()[0].kind, "ok");
  h.query(B); await flush(); assert.equal(h.createCalls.length, 1);
  assert.equal(h.results().length, 2);
});

test("without a normal browser window worker reports unavailable and does not open one", async () => {
  const h = workerHarness({ windows: [] }); await flush(); h.handshake(); h.query(); await flush();
  assert.equal(h.createCalls.length, 0);
  assert.equal(h.results()[0].kind, "browserUnavailable");
});

test("worker shares duplicate requests and drops a response after generation changes", async () => {
  const pending = deferred();
  const h = workerHarness(); await flush();
  h.tabs.set(4, message => message.type === "quota.query" ? pending.promise : h.defaultTab(message));
  h.readyTab(4); h.handshake(); h.query(); h.query(); await flush();
  assert.equal(h.tabCalls.filter(call => call.message.type === "quota.query").length, 1);
  h.handshake(H); pending.resolve({ kind: "ok", data: { usagePercent: 99 } }); await flush();
  assert.equal(h.results().length, 0);
  h.query(B, G); await flush(); assert.equal(h.results().length, 0);
  h.tabs.set(4, h.defaultTab); h.query(B, H); await flush();
  assert.equal(h.results()[0].generation, H); assert.equal(h.results()[0].id, B);
});

test("worker total deadline is 25 seconds; late responses cannot replace timeout", async () => {
  const pending = deferred();
  const h = workerHarness(); await flush();
  h.tabs.set(4, message => message.type === "quota.query" ? pending.promise : h.defaultTab(message));
  h.readyTab(4); h.handshake(); h.query(); await flush();
  await h.clock.advance(25_000);
  assert.equal(h.results().length, 1); assert.equal(h.results()[0].kind, "timeout");
  pending.resolve({ kind: "ok", data: { usagePercent: 0 } }); await flush();
  assert.equal(h.results().length, 1);
});

test("worker waits for content readiness and does not repeatedly create an unresponsive owned tab", async () => {
  const h = workerHarness({ autoReady: false }); await flush();
  // Simulate a page without a content receiver (e.g. a login navigation).
  const originalCreate = h.chrome.tabs.create;
  h.chrome.tabs.create = async options => {
    const tab = await originalCreate(options); h.tabs.set(tab.id, () => Promise.reject(new Error("No receiver"))); return tab;
  };
  h.handshake(); h.query(); await flush(); await h.clock.advance(25_000);
  assert.equal(h.results()[0].kind, "timeout"); assert.equal(h.createCalls.length, 1);
  h.query(B); await flush(); await h.clock.advance(25_000);
  assert.equal(h.createCalls.length, 1);
  assert.equal(h.results()[1].kind, "pageUnavailable");
  assert.equal(h.tabCalls.filter(call => call.message.type === "quota.query").length, 0);
});

test("navigated owned tab is preserved and one new inactive dashboard replaces it", async () => {
  const h = workerHarness({ session: { quotaTabIds: [5], ownedTabId: 5 } });
  h.tabs.set(5, () => Promise.reject(new Error("No dashboard receiver")));
  await flush(); h.handshake(); h.query(); await flush();
  assert.equal(h.tabs.has(5), true);
  assert.deepEqual(h.createCalls, [{ windowId: 1, active: false, url: "https://cursor.com/dashboard" }]);
  assert.equal(h.results()[0].kind, "ok");
});

test("a disconnect racing with ready alarm cleanup still schedules reconnection", async () => {
  const h = workerHarness(); await flush();
  h.alarms.set("native-reconnect", { periodInMinutes: 1 });
  const clear = deferred();
  h.chrome.alarms.clear = async name => { await clear.promise; h.alarms.delete(name); };
  h.handshake(); await flush();
  h.ports[0].disconnect(); await flush();
  clear.resolve(); await flush();
  assert.deepEqual(h.alarms.get("native-reconnect"), { delayInMinutes: 1, periodInMinutes: 1 });
});

test("worker validates and strips fields again before forwarding native results", async () => {
  const h = workerHarness(); await flush();
  h.tabs.set(6, message => message.type === "quota.query" ?
    { kind: "ok", data: { usagePercent: 9, unexpected: "private" }, body: "raw body" } : h.defaultTab(message));
  h.readyTab(6); h.handshake(); h.query(); await flush();
  assert.deepEqual(h.results()[0].data, { usagePercent: 9 });
  assert.equal(h.results()[0].body, undefined);
});

test("popup reconnect works when a native port already exists", async () => {
  const h = workerHarness(); await flush();
  await new Promise(resolve => h.chrome.runtime.onMessage.emit(
    { type: "popup.reconnect", version: 1 },
    { id: ID, url: `chrome-extension://${ID}/popup.html` }, resolve
  ));
  assert.equal(h.ports.length, 2); assert.equal(h.tabCalls.length, 0);
});

test("waiting-for-page state survives worker restart without creating extra login tabs", async () => {
  const h = workerHarness({ session: { quotaTabIds: [5], ownedTabId: 5, waitingForDashboard: true } });
  h.tabs.set(5, () => Promise.reject(new Error("No receiver")));
  await flush(); h.handshake(); h.query(); await flush();
  assert.equal(h.results()[0].kind, "pageUnavailable");
  assert.equal(h.createCalls.length, 0);
  h.tabs.set(5, h.defaultTab); h.readyTab(5); h.query(B); await flush();
  assert.equal(h.results()[1].kind, "ok");
});

test("popup only foregrounds the official page after an explicit account-button click", async () => {
  const clicks = {};
  const elements = Object.fromEntries(["status", "reconnect", "account"].map(id => [id, {
    textContent: "", disabled: false, addEventListener(type, callback) { clicks[id] = callback; }
  }]));
  const created = [];
  const context = vm.createContext({
    document: { getElementById: id => elements[id] },
    chrome: {
      runtime: { sendMessage: async () => ({ connected: true, ready: true }) },
      tabs: { create: async value => { created.push(plain(value)); } }
    }
  });
  vm.runInContext(files["popup.js"], context); await flush();
  assert.equal(created.length, 0);
  await clicks.reconnect(); assert.equal(created.length, 0);
  clicks.account(); await flush();
  assert.deepEqual(created, [{ url: "https://cursor.com/dashboard", active: true }]);
});
