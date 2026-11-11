(() => {
  "use strict";
  const P = globalThis.AIBalanceProtocol;
  const LIMIT = 65_536;
  let inFlight = null;

  async function boundedJSON(response) {
    const length = response.headers.get("content-length");
    if (length !== null && Number(length) > LIMIT) throw new Error("format");
    if (!response.body) throw new Error("format");
    const reader = response.body.getReader();
    const chunks = [];
    let total = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > LIMIT) throw new Error("format");
        chunks.push(value);
      }
    } catch (error) {
      await reader.cancel().catch(() => {});
      throw error;
    } finally { reader.releaseLock(); }
    const bytes = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    try { return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)); }
    catch { throw new Error("format"); }
  }

  async function readQuota(controller) {
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, 15_000);
    try {
      if (!P.atDashboard(location.href)) return { kind: "pageUnavailable" };
      const response = await fetch("/api/dashboard/get-sand-usage-status", {
        method: "POST", mode: "same-origin", credentials: "same-origin",
        redirect: "error", cache: "no-store", headers: { "Content-Type": "application/json" },
        body: "{}", signal: controller.signal
      });
      if (response.status === 401 || response.status === 403) return { kind: "loginRequired" };
      if (response.status === 429) return { kind: "rateLimited" };
      if (!response.ok) return { kind: "httpError" };
      const mime = (response.headers.get("content-type") || "").split(";", 1)[0].trim().toLowerCase();
      if (mime === "text/html") return { kind: "loginRequired" };
      if (mime !== "application/json") return { kind: "httpError" };
      const data = P.quotaFields(await boundedJSON(response));
      if (!P.atDashboard(location.href)) return { kind: "pageUnavailable" };
      return data ? { kind: "ok", data } : { kind: "httpError" };
    } catch (error) {
      if (timedOut) return { kind: "timeout" };
      if (controller.signal.aborted) return { kind: "pageUnavailable" };
      return { kind: error?.message === "format" ? "httpError" : "networkError" };
    } finally {
      clearTimeout(timer);
      controller.abort(); // Also stop an unread error/HTML response body.
    }
  }

  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (sender.id !== chrome.runtime.id || message?.version !== P.VERSION) return false;
    if (message.type === "quota.ping") {
      sendResponse({ type: "quota.pong", version: P.VERSION, available: P.atDashboard(location.href) });
      return false;
    }
    if (!P.isUUID(message.id) || !P.isUUID(message.generation)) return false;
    const key = `${message.generation}:${message.id}`;
    if (message.type === "quota.cancel") {
      if (inFlight?.key === key) inFlight.controller.abort();
      return false;
    }
    if (message.type !== "quota.query") return false;
    if (!P.atDashboard(location.href)) { sendResponse({ kind: "pageUnavailable" }); return false; }
    if (inFlight && inFlight.key !== key) { sendResponse({ kind: "pageUnavailable" }); return false; }
    if (!inFlight) {
      const controller = new AbortController();
      const current = { key, controller, promise: readQuota(controller) };
      inFlight = current;
      current.promise.finally(() => { if (inFlight === current) inFlight = null; });
    }
    inFlight.promise.then(sendResponse, () => sendResponse({ kind: "networkError" }));
    return true;
  });

  function announce() {
    if (P.atDashboard(location.href)) {
      chrome.runtime.sendMessage({ type: "quota.ready", version: P.VERSION }).catch(() => {});
    }
  }
  addEventListener("pageshow", announce);
  addEventListener("pagehide", () => inFlight?.controller.abort());
  announce();
})();
