#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。请先执行: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate

if [[ $# -gt 0 ]]; then
  DESTINATION="$1"
else
  DEVICE_UDID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
payload=json.load(sys.stdin)
for runtime, devices in payload.get("devices", {}).items():
    for device in devices:
        if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
            print(device["udid"])
            raise SystemExit
raise SystemExit("没有可用的 iPhone Simulator")
')"
  DESTINATION="platform=iOS Simulator,id=$DEVICE_UDID"
fi

xcodebuild \
  -project ESP32CarController.xcodeproj \
  -scheme ESP32CarController \
  -destination "$DESTINATION" \
  test
