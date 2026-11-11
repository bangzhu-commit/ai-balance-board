#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
test_build="$PWD/.build/codex-provider-checks"
mkdir -p "$test_build"
# 独立输出，不覆盖应用构建；测试只启动临时假 CLI，不调用真实账号或网络。
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$test_build/module-cache" \
  -parse-as-library -enable-testing -emit-module -emit-library -static -module-name BalanceCore \
  Sources/BalanceCore/*.swift -emit-module-path "$test_build/BalanceCore.swiftmodule" -o "$test_build/libBalanceCore.a"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$test_build/module-cache" \
  -parse-as-library -I "$test_build" -L "$test_build" -lBalanceCore \
  Sources/AIBalanceBoard/CodexExecutableResolver.swift Sources/AIBalanceBoard/CodexProvider.swift \
  scripts/CodexProviderChecks.swift -o "$test_build/CodexProviderChecks"
"$test_build/CodexProviderChecks"
