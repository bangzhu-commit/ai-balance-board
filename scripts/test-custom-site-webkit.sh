#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_dir="$PWD/.build/custom-provider-checks"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-cache"
mkdir -p "$build_dir"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -emit-module -emit-library -static -module-name BalanceCore \
  Sources/BalanceCore/*.swift -emit-module-path "$build_dir/BalanceCore.swiftmodule" -o "$build_dir/libBalanceCore.a"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  -parse-as-library -I "$build_dir" -L "$build_dir" -lBalanceCore \
  Sources/AIBalanceBoard/CustomSiteProvider.swift scripts/CustomSiteWebKitChecks.swift -o "$build_dir/CustomSiteWebKitChecks"
"$build_dir/CustomSiteWebKitChecks"
