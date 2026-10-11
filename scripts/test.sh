#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MIHOMO_BINARY="${MIHOMO_BINARY:-/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo}"
if [[ ! -x "$MIHOMO_BINARY" ]]; then
  echo "Set MIHOMO_BINARY to a readable Mihomo executable for isolated integration tests." >&2
  exit 1
fi
swift build --product EasyClashRecovery
swift run EasyClashTests
