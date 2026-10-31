#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "该脚本必须在 macOS 中运行。"
  read -r -p "按回车退出..."
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "未检测到 Xcode Command Line Tools，请先打开 Xcode 完成首次安装。"
  read -r -p "按回车退出..."
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未检测到 XcodeGen。"
  echo "请先在终端执行: brew install xcodegen"
  read -r -p "按回车退出..."
  exit 1
fi

chmod +x scripts/*.sh

echo "[1/3] 生成 Xcode 工程..."
xcodegen generate

echo "[2/3] 运行 iOS Simulator XCTest..."
./scripts/run_tests.sh

echo "[3/3] 构建未签名 IPA..."
./scripts/build_unsigned_ipa.sh

echo
echo "构建完成："
echo "$ROOT/build/ESP32CarController-unsigned.ipa"
open "$ROOT/build"
read -r -p "按回车关闭窗口..."
