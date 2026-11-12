#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/swift-module-cache"
# 当前机器的 SwiftPM ManifestAPI 与编译器不匹配；直接编译同一组源文件。
# 无外部依赖，不更改系统工具链。Package.swift 仍保留供标准 SwiftPM 环境使用。
build_dir="$PWD/.build/direct"
mkdir -p "$build_dir"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -enable-testing -emit-module -emit-library -static -module-name BalanceCore \
  Sources/BalanceCore/*.swift -emit-module-path "$build_dir/BalanceCore.swiftmodule" -o "$build_dir/libBalanceCore.a"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -I "$build_dir" -L "$build_dir" -lBalanceCore \
  Sources/AIBalanceBoard/*.swift -o "$build_dir/AIBalanceBoard"
app_path="$PWD/dist/AI 额度看板.app"
mkdir -p "$app_path/Contents/MacOS"
cp "$build_dir/AIBalanceBoard" "$app_path/Contents/MacOS/AIBalanceBoard"
cat > "$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIBalanceBoard</string>
<key>CFBundleIdentifier</key><string>local.outlier.ai-balance-board</string>
<key>CFBundleName</key><string>AI 额度看板</string>
<key>CFBundleDisplayName</key><string>AI 额度看板</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.1</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
resources="$app_path/Contents/Resources"
mkdir -p "$resources/scripts" "$resources/browser-extension"
# Bundle only runtime extension files and user-invoked installers, never tests/state.
for file in manifest.json background.js content.js protocol.js popup.html popup.js popup.css; do
  cp "browser-extension/$file" "$resources/browser-extension/$file"
done
for file in install-login-item.sh install-browser-bridge.sh uninstall.sh; do
  cp "scripts/$file" "$resources/scripts/$file"
  chmod 755 "$resources/scripts/$file"
done
codesign --force --sign - "$app_path"
print -r -- "$app_path"
