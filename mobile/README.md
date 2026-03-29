# PrivateDeploy Mobile

PrivateDeploy 的 Flutter 移动端，当前重点是把“在手机上直接管理和使用自建节点”这条链路做完整。

## 当前状态

- 主入口是一个工作台页，聚合 VPN 状态、云节点和本地配置。
- Android 原生 VPN 通路已接入，可直接连接、断开、重启并读取基础流量统计。
- iOS 工程、插件和 `VPNExtension` 已存在，但原生 VPN 需要在构建时额外嵌入 `VPNCore.framework`。
- `flutter analyze` 和 `flutter test` 当前均通过。

## 已实现能力

- VPN 连接管理
  - 连接、断开、重启
  - 连接状态与基础流量统计
  - 原生能力探测和不支持提示
- Vultr 云节点管理
  - 保存并校验 API Key
  - 拉取地域、套餐、实例列表
  - 在手机端直接创建和删除节点
  - 将节点信息转换为本地可用的 sing-box 配置
- 配置文件管理
  - 创建本地配置
  - 编辑和查看配置内容
  - 激活、删除本地配置
- 订阅导入
  - 从 URL 拉取订阅
  - 解析常见代理 URI / 响应内容并转成 sing-box 配置
- 云备份
  - 导出 API Key 和本地保存的节点记录
  - 从备份 JSON 恢复
- 节点详情
  - 查看 Shadowsocks / Hysteria2 / VLESS / Trojan 参数
  - 复制单项参数和整组链接

## 尚未落地或尚未产品化的部分

- 移动端 DigitalOcean 流程
- 独立的规则集管理页面
- 完整的多语言 UI 接入
- 图表、通知等依赖对应的产品功能
- 更细的页面拆分和导航结构

## 技术栈

- Flutter + Material 3
- `provider` 状态管理
- `dio` 网络请求
- `hive` + `shared_preferences` + `flutter_secure_storage` 本地存储
- Flutter Platform Channel + 原生 Android/iOS VPN 插件

## 目录概览

```text
mobile/
├── android/
├── ios/
├── lib/
│   ├── main.dart
│   ├── core/
│   │   ├── storage/
│   │   └── subscription/
│   ├── features/
│   │   ├── cloud/
│   │   ├── home/
│   │   ├── nodes/
│   │   ├── profiles/
│   │   ├── settings/
│   │   └── vpn/
│   ├── services/
│   └── shared/
└── test/
```

## 开发要求

- Flutter 3.x
- Dart 3.x
- Android Studio / Android SDK
- Xcode 15+（仅 iOS）

本仓库当前在本地用 Flutter `3.35.7` 验证过。

## 常用命令

```bash
cd mobile
/home/user/flutter/bin/flutter pub get
/home/user/flutter/bin/flutter analyze
/home/user/flutter/bin/flutter test
/home/user/flutter/bin/flutter run
```

Android Release 示例：

```bash
cd mobile
/home/user/flutter/bin/flutter build apk --release --target-platform android-arm,android-arm64 --split-per-abi
```

## 平台说明

### Android

- VPN Service 位于 `android/app/src/main/kotlin/com/privatedeploy/mobile/`
- Debug 构建允许明文流量，主 manifest 默认不再全局开启明文流量
- Release 构建签名可通过 `key.properties` 或环境变量注入

### iOS

- `Runner/VpnPlugin.swift` 和 `VPNExtension/PacketTunnelProvider.swift` 已接入
- 若未嵌入 `VPNCore.framework`，应用会显示原生 VPN 不可用，而不是假装可连
- 需要正确配置 App Group、Network Extension 和签名能力

## 测试

```bash
cd mobile
/home/user/flutter/bin/flutter analyze
/home/user/flutter/bin/flutter test
```

当前测试主要覆盖：

- network provider 状态流转
- Profile 存储与配置归一化
- Vultr client 请求和错误处理
- 订阅解析器
- 云备份与恢复逻辑

## 已知改进方向

- 继续拆分 `features/nodes/nodes_screen.dart`
- 把工作台页拆成更清晰的导航结构
- 同步 README 与产品实际能力，避免文档再次漂移
