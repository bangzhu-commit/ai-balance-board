#!/bin/bash
set -euo pipefail
# Remove integrations, not the app or account/session data. User invokes deliberately.
[[ $# -eq 3 && "$1" == '--integrations' && "$2" == '--app-path' && "$3" == /* ]] || {
  echo '用法：uninstall.sh --integrations --app-path <bundle>'; exit 2;
}
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
/bin/bash "$script_dir/install-login-item.sh" --disable --app-path "$3"
/bin/bash "$script_dir/install-browser-bridge.sh" --uninstall --app-path "$3"
echo '集成已移除。请手动移除 Chrome 扩展、退出看板，再把 app 移到废纸篓。账户会话和最近额度保留，未删除个人数据。'
