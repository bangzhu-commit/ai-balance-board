#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
setup_test_build="$PWD/.build/setup-integration-checks"
mkdir -p "$setup_test_build"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$setup_test_build/module-cache" \
  -parse-as-library Sources/AIBalanceBoard/SetupIntegration.swift scripts/SetupIntegrationChecks.swift \
  -o "$setup_test_build/SetupIntegrationChecks"
"$setup_test_build/SetupIntegrationChecks"
