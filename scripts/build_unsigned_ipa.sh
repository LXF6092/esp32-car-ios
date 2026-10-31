#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "缺少 XcodeGen。请先执行: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
rm -rf build/DerivedData build/Payload build/ESP32CarController-unsigned.ipa

xcodebuild \
  -project ESP32CarController.xcodeproj \
  -scheme ESP32CarController \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

APP="build/DerivedData/Build/Products/Release-iphoneos/ESP32CarController.app"
if [[ ! -d "$APP" ]]; then
  echo "未找到构建产物: $APP" >&2
  exit 1
fi

mkdir -p build/Payload
cp -R "$APP" build/Payload/
(
  cd build
  /usr/bin/zip -qry ESP32CarController-unsigned.ipa Payload
)

echo "未签名 IPA: $ROOT/build/ESP32CarController-unsigned.ipa"
