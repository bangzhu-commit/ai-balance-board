"use strict";
const statusElement = document.getElementById("status");
const reconnectButton = document.getElementById("reconnect");
async function refreshStatus() {
  try {
    const state = await chrome.runtime.sendMessage({ type: "popup.status", version: 1 });
    const messages = {
      loginRequired: "请在 Chrome 重新登录 Cursor",
      pageUnavailable: "用量页暂时无法读取",
      browserUnavailable: "需要一个普通 Chrome 窗口",
      networkError: "网络异常，保留上次读数",
      httpError: "额度接口暂不可用",
      timeout: "查询超时，等待下次刷新",
      rateLimited: "查询频率受限，稍后重试"
    };
    statusElement.textContent = !state?.connected ? "本机桥接未连接" :
      !state.ready ? "桥接已连接，等待看板" :
      messages[state.lastKind] || "已连接到本机看板";
  } catch { statusElement.textContent = "连接器暂不可用"; }
}
document.getElementById("account").addEventListener("click", () => {
  // The only foreground operation is this explicit user click.
  void chrome.tabs.create({ url: "https://cursor.com/dashboard", active: true });
});
reconnectButton.addEventListener("click", async () => {
  reconnectButton.disabled = true;
  try { await chrome.runtime.sendMessage({ type: "popup.reconnect", version: 1 }); }
  catch { statusElement.textContent = "本机桥接未连接"; }
  finally { reconnectButton.disabled = false; await refreshStatus(); }
});
void refreshStatus();
