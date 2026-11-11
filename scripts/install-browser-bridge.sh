#!/bin/bash
set -euo pipefail
umask 077
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo '命令行安装脚本需要 Apple Command Line Tools；普通用户请使用应用内设置。' >&2
    exit 1
fi
# All mutations are explicit user-invoked actions; never launch Chrome or inspect its profile.
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
user_home="$(/usr/bin/python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
app_path="$user_home/Applications/AI 额度看板.app"
extension_id='eghfefbgledejemklpphhpcfknmpbllf'
usage() { echo '用法：install-browser-bridge.sh --prepare | --install | --status | --uninstall [--app-path <bundle>]'; }
[[ $# -ge 1 ]] || { usage; exit 2; }
action="$1"; shift
case "$action" in --prepare|--install|--status|--uninstall) ;; --help|-h) usage; exit 0 ;; *) usage; exit 2 ;; esac
if [[ $# -gt 0 ]]; then
  [[ $# -eq 2 && "$1" == '--app-path' && "$2" == /* ]] || { usage; exit 2; }
  app_path="$2"
fi
[[ "$(id -u)" != 0 ]] || { echo '请使用当前桌面用户，不要 sudo。'; exit 1; }
support_dir="$user_home/Library/Application Support/AI Balance Board"
launcher="$support_dir/browser-bridge-host.sh"
extension_dir="$support_dir/Chrome Extension"
manifest_dir="$user_home/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_file="$manifest_dir/local.outlier.ai_balance_board.json"
if [[ "$action" == '--status' ]]; then
  /usr/bin/python3 - "$manifest_file" "$launcher" "$extension_dir" <<'PY'
import pathlib,sys
for label,path in zip(('Native Messaging 注册','本机桥接启动器','扩展目录'),sys.argv[1:]):
 p=pathlib.Path(path);print(label+'：'+('存在' if p.exists() and not p.is_symlink() else '未安装'))
print('扩展启用和账号登录状态由应用内连接检查确认；此检查不读取浏览器配置。')
PY
  exit 0
fi
# Validate actual installed app, including ad-hoc signature integrity; this is not notarization.
if [[ "$action" != '--prepare' ]]; then
[[ -d "$app_path" && ! -L "$app_path" ]] || { echo 'app 路径不存在或是符号链接。'; exit 1; }
app_path="$(cd "$app_path" && pwd -P)"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_path/Contents/Info.plist")" == 'local.outlier.ai-balance-board' ]] || exit 1
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$app_path/Contents/Info.plist")" == 'AIBalanceBoard' ]] || exit 1
bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$app_path/Contents/Info.plist")"
[[ "$bundle_version" =~ ^[0-9]+$ && "$bundle_version" -ge 4 ]] || { echo '需要支持 Chrome 连接的 v0.3.1 或更新版本。'; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app_path"
fi
# Runtime copies stage in TMPDIR, never attempt to write inside the signed app bundle.
stage_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-balance-board-bridge.XXXXXX")"
trap '/bin/rm -rf "$stage_dir"' EXIT
/usr/bin/python3 - "$stage_dir" "$launcher" "$app_path" "$extension_id" <<'PY'
import json,pathlib,shlex,sys
stage,launcher,app,extension_id=sys.argv[1:];stage=pathlib.Path(stage)
manifest={'name':'local.outlier.ai_balance_board','description':'AI 额度看板：只接收 Cursor 额度查询结果','path':launcher,'type':'stdio','allowed_origins':[f'chrome-extension://{extension_id}/']}
(stage/'local.outlier.ai_balance_board.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
(stage/'browser-bridge-host.sh').write_text('#!/bin/sh\nexec '+shlex.quote(app+'/Contents/MacOS/AIBalanceBoard')+' --browser-bridge-host "$@"\n')
PY
/bin/sh -n "$stage_dir/browser-bridge-host.sh"
if [[ "$action" == '--prepare' ]]; then
  # Preserve legacy prepare output only for a source checkout.
  [[ "$project_dir" != *.app/Contents/Resources ]] || { echo '应用内无需准备文件；请使用连接向导。'; exit 1; }
  mkdir -p "$project_dir/.build/browser-bridge-install"
  cp "$stage_dir/"* "$project_dir/.build/browser-bridge-install/"
  echo "可审阅安装文件：$project_dir/.build/browser-bridge-install"
  exit 0
fi
/usr/bin/python3 - "$action" "$support_dir" "$manifest_dir" "$manifest_file" "$launcher" "$extension_dir" "$stage_dir" "$project_dir/browser-extension" <<'PY'
import json,os,pathlib,stat,sys,tempfile
mode=sys.argv[1];support,manifest_dir,manifest,launcher,extension,stage,source=map(pathlib.Path,sys.argv[2:])
files=('manifest.json','background.js','content.js','protocol.js','popup.html','popup.js','popup.css')
def checked_dir(path,private=False,create=True):
 if path.is_symlink():raise SystemExit('拒绝符号链接目录')
 if path.exists():
  st=path.stat()
  if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid():raise SystemExit('目录所有者不匹配')
 elif create:
  checked_dir(path.parent);path.mkdir(mode=0o700)
 if private and path.exists():path.chmod(0o700)
def atomic_copy(src,dst,permissions):
 if src.is_symlink() or dst.is_symlink():raise SystemExit('拒绝符号链接文件')
 fd,tmp=tempfile.mkstemp(prefix='.bridge-',dir=dst.parent)
 try:
  with os.fdopen(fd,'wb') as f:f.write(src.read_bytes())
  os.chmod(tmp,permissions);os.replace(tmp,dst)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
for path in (support,manifest_dir,extension):checked_dir(path,create=False)
expected=json.loads((stage/manifest.name).read_text())
if manifest.exists() or manifest.is_symlink():
 if manifest.is_symlink() or json.loads(manifest.read_text())!=expected:raise SystemExit('同名 Native Messaging host 不属于本看板，停止处理')
if launcher.is_symlink():raise SystemExit('拒绝符号链接启动器')
if mode=='--uninstall':
 # Only remove owned registration/runtime files; retain readings and browser profile pairing.
 if launcher.exists() and launcher.read_bytes()!=(stage/launcher.name).read_bytes():raise SystemExit('启动器对应其他 app 路径，停止处理')
 for p in (manifest,launcher):
  if p.exists():p.unlink()
 if extension.exists():
  for name in files:
   p=extension/name
   if p.is_symlink():raise SystemExit('拒绝符号链接扩展文件')
   if p.is_file():p.unlink()
  if not any(extension.iterdir()):extension.rmdir()
 print('已移除本机通信注册与扩展运行文件。请在 Chrome 手动移除此扩展；额度与配对记录保留。')
else:
 checked_dir(support,True);checked_dir(support/'browser-bridge',True);checked_dir(manifest_dir);checked_dir(extension,True)
 for name in files:
  if not (source/name).is_file():raise SystemExit('扩展文件缺失：'+name)
 for name in files:atomic_copy(source/name,extension/name,0o600)
 atomic_copy(stage/launcher.name,launcher,0o700);atomic_copy(stage/manifest.name,manifest,0o600)
 print('已注册本机通信。请在 Chrome 加载：'+str(extension))
 print('未更改 Chrome 扩展设置，未读取 Cookie 或 token。')
PY
