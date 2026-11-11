"use strict";
importScripts("protocol.js");
const P = globalThis.AIBalanceProtocol;
const HOST = "local.outlier.ai_balance_board";
const ALARM = "native-reconnect";
const DASHBOARD = "https://cursor.com/dashboard";
const registered = new Set();
const readyWaiters = new Map();
let ownedTabId = null;
let ownedCreation = null;
let waitingForDashboard = false;
let alarmWork = Promise.resolve();
let port = null;
let generation = null;
let connectionEpoch = 0;
let connecting = null;
let inFlight = null;
let completed = null;
let lastKind = null;
let lastResponseAt = null;
let clientID = null;

const restored = chrome.storage.session.get(["quotaTabIds", "ownedTabId", "waitingForDashboard"]).then(saved => {
  const receivedLiveReady = registered.size > 0;
  for (const id of saved.quotaTabIds || []) if (Number.isInteger(id) && id >= 0) registered.add(id);
  if (Number.isInteger(saved.ownedTabId) && saved.ownedTabId >= 0) ownedTabId = saved.ownedTabId;
  if (!receivedLiveReady) waitingForDashboard = saved.waitingForDashboard === true;
}).catch(() => {});

function saveTabs() {
  return chrome.storage.session.set({ quotaTabIds: [...registered].slice(-16), ownedTabId, waitingForDashboard }).catch(() => {});
}
function waitFor(promise, milliseconds, signal) {
  return new Promise((resolve, reject) => {
    let finished = false;
    const finish = (fn, value) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      fn(value);
    };
    const abort = () => finish(reject, new Error("cancelled"));
    const timer = setTimeout(() => finish(reject, new Error("timeout")), milliseconds);
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
    Promise.resolve(promise).then(value => finish(resolve, value), error => finish(reject, error));
  });
}
function cancelCurrent() {
  if (!inFlight) return;
  inFlight.controller.abort();
  if (Number.isInteger(inFlight.tabId)) {
    chrome.tabs.sendMessage(inFlight.tabId, {
      type: "quota.cancel", version: P.VERSION, id: inFlight.id, generation: inFlight.generation
    }, { frameId: 0 }).catch(() => {});
  }
}
function current(ctx) {
  return !ctx.controller.signal.aborted && ctx.epoch === connectionEpoch && ctx.generation === generation;
}
async function ping(tabId, signal) {
  try {
    const value = await waitFor(chrome.tabs.sendMessage(tabId, {
      type: "quota.ping", version: P.VERSION
    }, { frameId: 0 }), 1_500, signal);
    return value?.type === "quota.pong" && value.version === P.VERSION && value.available === true;
  } catch { return false; }
}
function waitForReady(tabId, signal) {
  if (registered.has(tabId)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const callbacks = readyWaiters.get(tabId) || new Set();
    const finish = error => {
      callbacks.delete(finish);
      if (!callbacks.size) readyWaiters.delete(tabId);
      signal.removeEventListener("abort", abort);
      if (error) reject(error); else resolve();
    };
    const abort = () => finish(new Error("cancelled"));
    callbacks.add(finish);
    readyWaiters.set(tabId, callbacks);
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
}
async function getOwnedTab(ctx) {
  if (ownedCreation) return ownedCreation;
  ownedCreation = (async () => {
    if (Number.isInteger(ownedTabId)) {
      const previous = ownedTabId;
      try {
        await chrome.tabs.get(previous);
        if (await ping(previous, ctx.controller.signal)) {
          registered.add(previous);
          return previous;
        }
      } catch { /* Closed or navigated tabs are never changed. */ }
      // The user may have navigated this tab elsewhere. Release ownership,
      // preserve its current contents, and create one replacement below.
      registered.delete(previous);
      ownedTabId = null;
      await saveTabs();
    }
    const windows = await chrome.windows.getAll({ windowTypes: ["normal"] });
    if (!current(ctx)) return null;
    const window = windows.find(item => item.type === "normal" && !item.incognito && Number.isInteger(item.id));
    if (!window) return null;
    // Never create/focus a window or replace a user's navigation.
    const tab = await chrome.tabs.create({ windowId: window.id, active: false, url: DASHBOARD });
    if (!Number.isInteger(tab.id)) return null;
    ownedTabId = tab.id;
    await saveTabs();
    return tab.id;
  })();
  try { return await ownedCreation; }
  finally { ownedCreation = null; }
}
async function runQuery(ctx) {
  await restored;
  for (const tabId of [...registered].reverse()) {
    if (!current(ctx)) return { kind: "pageUnavailable" };
    if (await ping(tabId, ctx.controller.signal)) { ctx.tabId = tabId; break; }
    registered.delete(tabId);
  }
  if (!current(ctx)) return { kind: "pageUnavailable" };
  if (!Number.isInteger(ctx.tabId)) {
    if (waitingForDashboard) return { kind: "pageUnavailable" };
    const tabId = await getOwnedTab(ctx);
    if (!current(ctx)) return { kind: "pageUnavailable" };
    if (tabId === null) return { kind: "browserUnavailable" };
    ctx.tabId = tabId;
    if (await ping(tabId, ctx.controller.signal)) registered.add(tabId);
    if (!current(ctx)) return { kind: "pageUnavailable" };
    ctx.awaitingReady = !registered.has(tabId);
    await waitForReady(tabId, ctx.controller.signal);
    ctx.awaitingReady = false;
  }
  await saveTabs();
  if (!current(ctx)) return { kind: "pageUnavailable" };
  const result = await chrome.tabs.sendMessage(ctx.tabId, {
    type: "quota.query", version: P.VERSION, id: ctx.id, generation: ctx.generation
  }, { frameId: 0 });
  return P.cleanResult(result);
}
function postResult(query, result, epoch) {
  if (!port || epoch !== connectionEpoch || generation !== query.generation) return;
  const safe = P.cleanResult(result);
  lastKind = safe.kind;
  lastResponseAt = Date.now();
  try { port.postMessage({ type: "result", version: P.VERSION, id: query.id, generation: query.generation, ...safe }); }
  catch { /* onDisconnect owns reconnection. */ }
}
async function handleQuery(query, epoch) {
  if (query?.version !== P.VERSION || query.type !== "query" || !P.isUUID(query.id) ||
      !P.isUUID(query.generation) || query.generation !== generation || epoch !== connectionEpoch) return;
  const key = `${query.generation}:${query.id}`;
  if (completed?.key === key) { postResult(query, completed.result, epoch); return; }
  if (inFlight) {
    if (inFlight.key !== key) postResult(query, { kind: "pageUnavailable" }, epoch);
    return; // The original request sends the shared result once.
  }
  const ctx = {
    key, id: query.id, generation: query.generation, epoch,
    controller: new AbortController(), tabId: null
  };
  inFlight = ctx;
  let result;
  try {
    result = await waitFor(runQuery(ctx), 25_000, ctx.controller.signal);
  } catch (error) {
    result = { kind: error?.message === "timeout" ? "timeout" : "pageUnavailable" };
    if (error?.message === "timeout" && ctx.awaitingReady && current(ctx)) {
      waitingForDashboard = true;
      void saveTabs();
    }
  }
  const maySend = current(ctx);
  if (inFlight === ctx) { cancelCurrent(); inFlight = null; }
  if (maySend) {
    completed = { key, result: P.cleanResult(result) };
    postResult(query, result, epoch);
  }
}
function scheduleReconnect() {
  // Serialize clear/create so a fast disconnect cannot lose the reconnect alarm.
  alarmWork = alarmWork.catch(() => {}).then(async () => {
    if (port && generation) { await chrome.alarms.clear(ALARM); return; }
    if (port) return;
    if (!(await chrome.alarms.get(ALARM))) {
      await chrome.alarms.create(ALARM, { delayInMinutes: 1, periodInMinutes: 1 });
    }
  }).catch(() => { /* Browser shutdown can invalidate extension APIs. */ });
  return alarmWork;
}
async function getClientID() {
  if (clientID) return clientID;
  const saved = await chrome.storage.local.get("clientID");
  clientID = P.isUUID(saved.clientID) ? saved.clientID : crypto.randomUUID();
  if (clientID !== saved.clientID) await chrome.storage.local.set({ clientID });
  return clientID;
}
function connectNative() {
  if (port) return Promise.resolve();
  if (connecting) return connecting;
  connecting = (async () => {
    try {
      const id = await getClientID();
      const next = chrome.runtime.connectNative(HOST);
      const epoch = ++connectionEpoch;
      port = next;
      generation = null;
      completed = null;
      next.onMessage.addListener(message => {
        if (port !== next || epoch !== connectionEpoch) return;
        if (message?.type === "ready" && message.version === P.VERSION && P.isUUID(message.generation)) {
          if (generation !== message.generation) { cancelCurrent(); inFlight = null; completed = null; }
          generation = message.generation;
          void scheduleReconnect();
          return;
        }
        void handleQuery(message, epoch);
      });
      next.onDisconnect.addListener(() => {
        void chrome.runtime.lastError; // Deliberately do not retain native error text.
        if (port !== next) return;
        cancelCurrent(); inFlight = null;
        port = null; generation = null; completed = null;
        ++connectionEpoch;
        void scheduleReconnect();
      });
      next.postMessage({ type: "hello", version: P.VERSION, clientID: id });
    } catch {
      if (port) { try { port.disconnect(); } catch {} }
      port = null; generation = null;
      await scheduleReconnect();
    }
  })().finally(() => { connecting = null; });
  return connecting;
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || message?.version !== P.VERSION) return false;
  if (message.type === "quota.ready") {
    if (sender.frameId !== 0 || !Number.isInteger(sender.tab?.id) || !P.atDashboard(sender.url)) return false;
    const tabId = sender.tab.id;
    registered.add(tabId);
    waitingForDashboard = false;
    for (const finish of [...(readyWaiters.get(tabId) || [])]) finish();
    void restored.then(saveTabs);
    return false;
  }
  if (sender.tab || sender.url !== chrome.runtime.getURL("popup.html")) return false;
  if (message.type === "popup.status") {
    sendResponse({ connected: Boolean(port), ready: Boolean(generation), lastKind, lastResponseAt });
    return false;
  }
  if (message.type === "popup.reconnect") {
    const old = port;
    cancelCurrent(); inFlight = null;
    port = null; generation = null; completed = null;
    ++connectionEpoch;
    waitingForDashboard = false;
    void saveTabs();
    if (old) { try { old.disconnect(); } catch {} }
    connectNative().then(() => sendResponse({ ok: true }), () => sendResponse({ ok: false }));
    return true;
  }
  return false;
});
chrome.tabs.onRemoved.addListener(tabId => {
  registered.delete(tabId);
  if (ownedTabId === tabId) { ownedTabId = null; waitingForDashboard = false; }
  void restored.then(saveTabs);
});
chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === ALARM && !port) void connectNative();
});
chrome.runtime.onStartup.addListener(() => { void connectNative(); });
chrome.runtime.onInstalled.addListener(() => { void connectNative(); });
void connectNative();
