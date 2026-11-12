#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_dir="$PWD/.build/edit-menu-checks"
mkdir -p "$build_dir"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  -parse-as-library Sources/AIBalanceBoard/AppMenus.swift scripts/EditMenuChecks.swift \
  -o "$build_dir/EditMenuChecks"
"$build_dir/EditMenuChecks"
