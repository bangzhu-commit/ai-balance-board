#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_dir="$PWD/.build/checks"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swift-module-cache"
mkdir -p "$build_dir"
# 仅依赖系统 Swift 编译器；不使用 SwiftPM 或 XCTest，不运行任何网络接入。
# 独立输出目录避免与生产应用构建互相覆盖。
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -enable-testing -emit-module -emit-library -static -module-name BalanceCore \
  Sources/BalanceCore/*.swift -emit-module-path "$build_dir/BalanceCore.swiftmodule" -o "$build_dir/libBalanceCore.a"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -I "$build_dir" -L "$build_dir" -lBalanceCore \
  Tests/BalanceCoreTests/*.swift -o "$build_dir/ParserChecks"
"$build_dir/ParserChecks"
