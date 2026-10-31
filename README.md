# ESP32 小车 iPhone 原生控制 App

这是 iOS 16+ SwiftUI 原生控制器，使用 BLE 直接连接 `ESP32-CAR-BLE`，不依赖小车 Wi-Fi、网页、自签名 HTTPS 或 Safari 前台定时器。

## 首版功能

- 自动扫描、连接和前台重连
- 四轮与超声波遥测
- 摇杆、方向键、横移、原地旋转
- CoreMotion 体感控制和姿态标定
- Apple Speech 一次一条白名单语音指令
- 完全离线的快捷口令
- 使能、停车、急停、急停复位
- App 退后台、蓝牙断开或数据过期立即停车，重连不自动恢复动作

## Mac 环境

需要：

- macOS
- Xcode（支持 iOS 16 SDK 或更新版本）
- Xcode Command Line Tools
- XcodeGen

安装 XcodeGen：

```bash
brew install xcodegen
```

## 生成 Xcode 工程

```bash
cd ios_car_controller
xcodegen generate
open ESP32CarController.xcodeproj
```

在 Xcode 中选择自己的 iPhone。开发调试可使用个人 Team；最终 Bundle ID 和签名由您的签名工具或 Xcode 配置。

## 运行测试

```bash
./scripts/run_tests.sh
```

也可以传入其他模拟器：

```bash
./scripts/run_tests.sh "platform=iOS Simulator,name=iPhone 16"
```

## 生成未签名 IPA

```bash
./scripts/build_unsigned_ipa.sh
```

输出：

```text
build/ESP32CarController-unsigned.ipa
```

该 IPA 尚未签名，需要使用您的证书、描述文件和签名工具完成重签名后安装。签名工具只能签名现有 IPA，不能替代 Xcode 编译 Swift 源码。

## 权限

首次启动会请求：

- Bluetooth：连接 ESP32 小车
- Motion：体感控制
- Microphone：采集语音
- Speech Recognition：识别受限驾驶口令

App 不申请后台驾驶权限。进入后台或锁屏时会发送 STOP 并主动断开 BLE，让 ESP32 立即撤销使能。

## BLE 协议

协议文档与共享测试向量位于：

- `Protocol/ble_v1.md`
- `Protocol/ble_v1_vectors.json`

ESP32 固件必须包含 `ble_protocol.py` 与 `ble_control.py`，并在启动日志中显示 `BLE_ENABLED`。
