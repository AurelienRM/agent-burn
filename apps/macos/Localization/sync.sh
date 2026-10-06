#!/usr/bin/env bash
# Extract interface strings from the Swift sources into Localizable.xcstrings.
# New keys arrive untranslated; stale keys are marked so they can be removed.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
touch Sources/AgentBurn/*.swift
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$out"
xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata "$out"/*.stringsdata
