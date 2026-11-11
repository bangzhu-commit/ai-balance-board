#!/bin/bash
set -euo pipefail
umask 077
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo '命令行安装脚本需要 Apple Command Line Tools；普通用户请使用应用内设置。' >&2
    exit 1
fi

# 仅管理本看板的当前用户启动项。依据本机 launchd.plist(5) / launchctl(1)：
# gui/<uid> 是 GUI 登录域；RunAtLoad 只在加载时启动一次；disable 跨重启保存。
# 不设 KeepAlive、StartInterval、StartCalendarInterval，不使用 open -n。
# --enable 会写入用户目录并 bootstrap；必须由操作者在授权后执行。

label='local.outlier.ai-balance-board.login'
bundle_id='local.outlier.ai-balance-board'
app_name='AI 额度看板.app'
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
user_id="$(/usr/bin/id -u)"
user_home="$(/usr/bin/python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
domain="gui/${user_id}"
service="${domain}/${label}"
source_app="${project_dir}/dist/${app_name}"
apps_dir="${user_home}/Applications"
target_app="${apps_dir}/${app_name}"
backup_dir="${apps_dir}/.AI-Balance-Board-Backups"
backup_app="${backup_dir}/AI 额度看板.previous.app"
agents_dir="${user_home}/Library/LaunchAgents"
target_plist="${agents_dir}/${label}.plist"
prepared_dir="${project_dir}/.build/login-item"
prepared_plist="${prepared_dir}/${label}.plist"
stage_dir=''
plist_stage=''
old_app_moved=0
old_backup_moved=0
app_committed=0

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
用法：scripts/install-login-item.sh --prepare | --enable | --register | --disable | --status [--app-path <bundle>]
  --prepare  只在项目 .build/login-item 生成待审阅 plist；不调用 launchctl。
  --enable   安装到 ~/Applications，保留上一版本，启用并后台打开一次。
  --register  仅注册指定已安装 app 的登录启动项，不复制或重启当前 app。
  --disable  禁用并卸载此登录启动项；保留 app、plist 和运行中的看板。
  --status   只读查看本项的文件、加载状态及进程状态。
启用前请退出已有看板；脚本不会终止任何应用或其他启动项。
USAGE
}

assert_not_link() { [[ ! -L "$1" ]] || die "路径是符号链接，停止处理：$1"; }
validate_app() {
    local path="$1" found executable
    assert_not_link "$path"
    [[ -d "$path" && -f "$path/Contents/Info.plist" ]] || die "不是预期 app bundle：$path"
    assert_not_link "$path/Contents/Info.plist"
    found="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$path/Contents/Info.plist")" || die "无法读取 bundle id：$path"
    [[ "$found" == "$bundle_id" ]] || die "目标 bundle id 不匹配，不会覆盖：$path"
    executable="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$path/Contents/Info.plist")" || die "缺少可执行文件名称：$path"
    [[ "$executable" == 'AIBalanceBoard' && -x "$path/Contents/MacOS/AIBalanceBoard" ]] || die "可执行文件不符合预期：$path"
}

validate_plist() {
    local path="$1"
    assert_not_link "$path"
    # 比较完整字典，拒绝同名但运行其他命令、包含额外触发条件的启动项。
    /usr/bin/python3 - "$path" "$label" "$target_app" <<'PY' || die "启动项内容不是本脚本管理的预期配置，不会覆盖：$path"
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    actual = plistlib.load(stream)
expected = {
    'Label': sys.argv[2],
    'ProgramArguments': ['/usr/bin/open', '-g', sys.argv[3]],
    'RunAtLoad': True,
    'LimitLoadToSessionType': 'Aqua',
}
if actual != expected:
    raise SystemExit(1)
PY
}

prepare_plist() {
    assert_not_link "${project_dir}/.build"
    assert_not_link "$prepared_dir"
    /bin/mkdir -p "$prepared_dir"
    assert_not_link "$prepared_plist"
    /usr/bin/python3 - "$prepared_plist" "$label" "$target_app" <<'PY'
import os, plistlib, sys, tempfile
document = {
    'Label': sys.argv[2],
    'ProgramArguments': ['/usr/bin/open', '-g', sys.argv[3]],
    'RunAtLoad': True,
    'LimitLoadToSessionType': 'Aqua',
}
fd, temporary = tempfile.mkstemp(prefix='.login-plist-', dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd, 'wb') as stream:
        plistlib.dump(document, stream, fmt=plistlib.FMT_XML, sort_keys=False)
    os.replace(temporary, sys.argv[1])
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
    /usr/bin/plutil -lint "$prepared_plist"
    validate_plist "$prepared_plist"
}

cleanup() {
    local result=$?
    trap - EXIT
    # app 交换尚未完成时，恢复原 app 与原备份；完成后只保留一个上一版。
    if [[ "$app_committed" -eq 0 ]]; then
        if [[ "$old_app_moved" -eq 1 && ! -e "$target_app" ]]; then
            /bin/mv "$backup_app" "$target_app" || say "需手动恢复：$backup_app → $target_app" >&2
        fi
        if [[ "$old_backup_moved" -eq 1 && ! -e "$backup_app" && -d "$stage_dir/previous-backup.app" ]]; then
            /bin/mv "$stage_dir/previous-backup.app" "$backup_app" || say "旧备份保留于：$stage_dir/previous-backup.app" >&2
        fi
    fi
    if [[ -n "$plist_stage" && "$plist_stage" == "$agents_dir/.${label}."* ]]; then
        /bin/rm -f "$plist_stage"
    fi
    if [[ -n "$stage_dir" && "$stage_dir" == "$apps_dir/.ai-balance-board-stage."* ]]; then
        # 失败且恢复未完成时保留暂存目录，不删除任何待恢复版本。
        if [[ "$app_committed" -eq 1 || ( "$old_app_moved" -eq 0 && "$old_backup_moved" -eq 0 ) || ( -d "$target_app" && ! -e "$stage_dir/previous-backup.app" ) ]]; then
            /bin/rm -rf "$stage_dir"
        else
            say "暂存目录保留供恢复：$stage_dir" >&2
        fi
    fi
    exit "$result"
}

[[ $# -ge 1 ]] || { usage; exit 2; }
action="$1"; shift
case "$action" in --prepare|--enable|--register|--disable|--status) ;; --help|-h) usage; exit 0 ;; *) usage; exit 2 ;; esac
if [[ $# -gt 0 ]]; then
    [[ $# -eq 2 && "$1" == '--app-path' && "$2" == /* && "$action" != '--enable' ]] || { usage; exit 2; }
    target_app="$2"
    [[ -d "$target_app" && ! -L "$target_app" ]] || die 'app 路径不存在或是符号链接。'
    target_app="$(cd "$target_app" && pwd -P)"
fi
set -- "$action"
[[ "$user_id" -ne 0 ]] || die "请以当前桌面用户运行，不要 sudo。"
[[ "$user_home" == /* && "$user_home" != '/' ]] || die '无法确认当前用户主目录。'

if [[ "$1" == '--prepare' ]]; then
    prepare_plist
    say "待审阅配置：$prepared_plist"
    say "安装目标：$target_app"
    say "启动项目标：$target_plist"
    exit 0
fi

assert_not_link "$apps_dir"
assert_not_link "$agents_dir"
assert_not_link "$target_plist"
if [[ -e "$target_plist" ]]; then validate_plist "$target_plist"; fi
if [[ -e "$target_app" || -L "$target_app" ]]; then validate_app "$target_app"; fi

if [[ "$1" == '--status' ]]; then
    say "应用：$target_app"
    [[ -d "$target_app" ]] && say '应用文件：已安装' || say '应用文件：未安装'
    [[ -f "$target_plist" ]] && say '启动项文件：存在且校验通过' || say '启动项文件：不存在'
    if /bin/launchctl print "$service" >/dev/null 2>&1; then say '当前登录域：已加载'; else say '当前登录域：未加载'; fi
    if /usr/bin/pgrep -u "$user_id" -x AIBalanceBoard >/dev/null; then say '看板进程：正在运行'; else say '看板进程：未运行'; fi
    say '本项 disabled 原始记录（true 表示禁用；空白表示无显式记录）：'
    # 仅供人阅读，不把 launchctl 的非稳定输出作为自动化状态机输入。
    /bin/launchctl print-disabled "$domain" 2>/dev/null | /usr/bin/awk -v key="\"$label\"" 'index($0,key) { print }' || true
    exit 0
fi

/bin/launchctl print "$domain" >/dev/null 2>&1 || die '当前用户没有可用 GUI 登录域；请登录桌面后执行。'
if /bin/launchctl print "$service" >/dev/null 2>&1 && [[ ! -f "$target_plist" ]]; then
    die '存在同名已加载任务，但没有可验证的启动项文件；停止处理。'
fi

if [[ "$1" == '--disable' ]]; then
    if [[ ! -f "$target_plist" ]]; then say '未安装此登录启动项，无需更改。'; exit 0; fi
    /bin/launchctl disable "$service"
    if /bin/launchctl print "$service" >/dev/null 2>&1; then /bin/launchctl bootout "$service"; fi
    say '已禁用本看板的登录自启动；app 与配置保留，运行中的看板不会被关闭。'
    exit 0
fi

if [[ "$1" == '--register' ]]; then
    validate_app "$target_app"
    /usr/bin/codesign --verify --deep --strict "$target_app" || die '应用签名校验失败。'
    prepared_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ai-balance-board-login.XXXXXX")"
    prepared_plist="$prepared_dir/$label.plist"
    trap '/bin/rm -rf "$prepared_dir"' EXIT
    prepare_plist
    /bin/mkdir -p "$agents_dir"
    plist_stage="$(/usr/bin/mktemp "$agents_dir/.${label}.XXXXXX")"
    /bin/cp "$prepared_plist" "$plist_stage"
    /bin/chmod 600 "$plist_stage"
    /bin/mv -f "$plist_stage" "$target_plist"
    /bin/launchctl enable "$service"
    if /bin/launchctl print "$service" >/dev/null 2>&1; then /bin/launchctl bootout "$service"; fi
    /bin/launchctl bootstrap "$domain" "$target_plist"
    say '已启用登录自启动。应用文件未替换；当前实例继续运行。'
    exit 0
fi

validate_app "$source_app"
/usr/bin/codesign --verify --deep --strict "$source_app" || die '构建产物签名校验失败。'
if /usr/bin/pgrep -u "$user_id" -x AIBalanceBoard >/dev/null; then
    die '请先退出已有 AI 额度看板，再启用或更新；脚本不会终止进程。'
fi
assert_not_link "$backup_dir"
if [[ -e "$backup_app" || -L "$backup_app" ]]; then validate_app "$backup_app"; fi
prepare_plist
/bin/mkdir -p "$apps_dir" "$agents_dir" "$backup_dir"
stage_dir="$(/usr/bin/mktemp -d "$apps_dir/.ai-balance-board-stage.XXXXXX")"
trap cleanup EXIT
/usr/bin/ditto "$source_app" "$stage_dir/$app_name"
validate_app "$stage_dir/$app_name"
/usr/bin/codesign --verify --deep --strict "$stage_dir/$app_name" || die '暂存 app 签名校验失败。'
plist_stage="$(/usr/bin/mktemp "$agents_dir/.${label}.XXXXXX")"
/bin/cp "$prepared_plist" "$plist_stage"
/bin/chmod 600 "$plist_stage"
validate_plist "$plist_stage"

if [[ -d "$target_app" ]] && /usr/bin/diff -qr "$source_app" "$target_app" >/dev/null; then
    app_committed=1
else
    if [[ -d "$backup_app" ]]; then
        /bin/mv "$backup_app" "$stage_dir/previous-backup.app"
        old_backup_moved=1
    fi
    if [[ -d "$target_app" ]]; then
        /bin/mv "$target_app" "$backup_app"
        old_app_moved=1
    fi
    /bin/mv "$stage_dir/$app_name" "$target_app"
    app_committed=1
fi
/bin/mv -f "$plist_stage" "$target_plist"
plist_stage=''
/bin/launchctl enable "$service"
if /bin/launchctl print "$service" >/dev/null 2>&1; then /bin/launchctl bootout "$service"; fi
if ! /bin/launchctl bootstrap "$domain" "$target_plist"; then
    die "app 与 plist 已安装，但当前登录域加载失败。旧版备份：$backup_app；检查后可重试 --enable。"
fi
/bin/launchctl print "$service" >/dev/null 2>&1 || die 'bootstrap 返回成功，但无法确认任务已加载。'
say '已安装并加载登录启动项，系统已接受后台打开请求。'
say '只在登录或显式启用时打开一次；主动退出后不会自动重启。'
say "安装位置：$target_app"
[[ -d "$backup_app" ]] && say "上一版本：$backup_app"
say '可运行 --status 查看状态，--disable 取消登录自启动。'
