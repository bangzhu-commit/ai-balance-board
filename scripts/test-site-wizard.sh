#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
build_dir="$PWD/.build/site-wizard-checks"
mkdir -p "$build_dir"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  -parse-as-library -emit-module -emit-library -static -module-name BalanceCore \
  Sources/BalanceCore/*.swift -emit-module-path "$build_dir/BalanceCore.swiftmodule" -o "$build_dir/libBalanceCore.a"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$build_dir/module-cache" \
  -parse-as-library -I "$build_dir" -L "$build_dir" -lBalanceCore \
  Sources/AIBalanceBoard/CustomSiteEditorModel.swift scripts/SiteWizardChecks.swift -o "$build_dir/SiteWizardChecks"
"$build_dir/SiteWizardChecks"
