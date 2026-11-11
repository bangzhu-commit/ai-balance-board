(() => {
  "use strict";
  const VERSION = 1;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const PROTO_NUMBER = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?$/;
  const KEYS = Object.freeze([
    "usagePercent", "hasNonZeroIncludedLimit", "nextResetTimestampUtc",
    "isTeamSeat", "usesPooledEnterpriseAllowance", "sandTrialExpiresAt", "isUnified"
  ]);
  const KINDS = new Set([
    "ok", "loginRequired", "httpError", "pageUnavailable", "networkError",
    "browserUnavailable", "timeout", "rateLimited"
  ]);
  const isUUID = value => typeof value === "string" && UUID.test(value);
  function atDashboard(value) {
    try {
      const url = new URL(value);
      return url.origin === "https://cursor.com" &&
        (url.pathname === "/dashboard" || url.pathname.startsWith("/dashboard/"));
    } catch { return false; }
  }
  // Only small, known scalar quota fields cross the extension/native boundary.
  // Missing and null values stay missing/null; they never become zero.
  function quotaFields(body) {
    if (!body || typeof body !== "object" || Array.isArray(body)) return null;
    const result = {};
    for (const key of KEYS) {
      if (!Object.prototype.hasOwnProperty.call(body, key)) continue;
      const value = body[key];
      if (value !== null) {
        if (key === "usagePercent") {
          if (!(typeof value === "number" || typeof value === "string") ||
              (typeof value === "string" && (value.length > 40 || !PROTO_NUMBER.test(value))) ||
              !Number.isFinite(Number(value)) || Number(value) < 0) return null;
        } else if (key === "nextResetTimestampUtc" || key === "sandTrialExpiresAt") {
          if (typeof value !== "string" || value.length > 80) return null;
        } else if (typeof value !== "boolean") return null;
      }
      result[key] = value;
    }
    return Object.keys(result).length ? result : null;
  }
  function cleanResult(value) {
    if (!value || typeof value !== "object" || !KINDS.has(value.kind)) return { kind: "httpError" };
    if (value.kind !== "ok") return { kind: value.kind };
    const data = quotaFields(value.data);
    return data ? { kind: "ok", data } : { kind: "httpError" };
  }
  globalThis.AIBalanceProtocol = Object.freeze({ VERSION, KEYS, isUUID, atDashboard, quotaFields, cleanResult });
})();
