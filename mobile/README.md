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

## 云服务商支持

- **Vultr** — 完整流程(列 region/plan、创建、删除、节点恢复)
- **DigitalOcean** — 完整流程(与 Vultr 对齐);设置 → API Key 对话框顶部可切换当前激活的服务商。每个服务商的 API Key 与节点记录在本地以命名空间隔离(`mobile_cloud_<provider>_api_key` / `..._nodes`),切换不会丢失另一侧数据。

## 尚未落地或尚未产品化的部分

- 同时展示多个云服务商节点(当前为"单活服务商",UI 一次仅显示当前激活者的节点)
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

#### 模拟器调试镜像选择（重要）

在 Android 模拟器上跑 **Flutter debug APK** 时，请使用 `google_apis/x86_64` 系统镜像，**不要**用 `default/x86_64`。

实测在 API 33 / API 34 的 default x86_64 镜像上，Flutter 加载 `kernel_blob.bin` 会失败：

```
E flutter : Dart Error: Can't load Kernel binary: Invalid kernel binary: Indicated size is invalid.
E flutter : Could not prepare isolate.
E flutter : Could not create root isolate.
```

症状：native 进程存活，但应用永远停留在 Splash Logo，看起来像启动慢。`flutter run` / `adb logcat` 里能看到上述错误。

- 仅影响 **debug** 构建（JIT，运行时加载 dill）；release 走 AOT (`libapp.so`)，不读 kernel_blob，**不受影响**
- 已验证不受影响的 API：31 / 32 / 35 / 36（无论镜像类型）和 API 34 google_apis
- 已验证有问题的 AVD：API 33 default、API 34 default
- 排查思路：如 UI 卡 Splash，先 `adb logcat | grep "Could not create root isolate"`，命中即换 google_apis 镜像或改用 release 构建

### iOS

iOS 是 **beta / 构建依赖型** 平台：Swift 插件和 PacketTunnel 扩展骨架都已就位，但所有原生 VPN 入口都被 `#if canImport(VPNCore)` 包裹，没有 `VPNCore.framework` 嵌入时只会返回明确的 unsupported 错误（不会假装能连）。要让 iOS 上的 VPN 真正可用，需要按 [`IOS_INTEGRATION.md`](IOS_INTEGRATION.md) 走一遍 gomobile framework 构建并配置签名与权能：

1. **gomobile 编译 VPNCore.framework**

   ```bash
   cd mobile/gomobile
   ./build-ios.sh
   ```

   产物会写到 `mobile/ios/VPNCore.framework`，把它拖入 Xcode 的 Runner target,并选 *Embed & Sign*。

2. **App Group**：在主 App 与 `VPNExtension` 两个 target 都启用 `App Groups`，并加入 `group.com.privatedeploy.mobile`（或自定义后改 `Info.plist` 里的 `PrivateDeployVPNAppGroup`）。

3. **Network Extension**：为两个 target 都启用 `Network Extensions → Packet Tunnel`。

4. **签名能力**：使用一个开启了 `Network Extensions` 权能的 Apple Developer 账号，否则 `NETunnelProviderManager.saveToPreferences` 会失败。

5. 在主 App `Info.plist` 中确认 `PrivateDeployVPNExtensionBundleIdentifier` 指向 `VPNExtension` 的实际 bundle id。

iOS 平台未覆盖的功能（对齐桌面）：

- 没有 `accountStatus` 探测：桌面端的 DigitalOcean locked / Vultr 防火墙 50/50 配额预检尚未在 iOS 复刻；iOS 侧仍只在调用 `validateApiKey` 时通过 HTTP 错误反馈
- 没有 `RepairCloudInstance`：桌面端的就地修复/重新部署仅有桌面 Wails RPC，iOS 仅有删除+重建的常规流程
- VPN 系统状态 stream 在没有 `VPNCore.framework` 时仅返回静态的 unsupported 事件，不会主动推送状态变化

## 测试

### Unit + Widget 测试

```bash
cd mobile
/home/user/flutter/bin/flutter analyze
/home/user/flutter/bin/flutter test
```

当前 `test/` 主要覆盖：

- `vpn_provider_test.dart` — VPN 状态流转、startup probe degraded 路径、`stopDegradedSession`
- `nodes_vpn_actions_test.dart` — `connectSelectedProfile` / `handleNodesConnect` / `autoFailoverToNextCloudNode` 全部分支
  - 含 Hive 保存档失败转移、upstream-degraded 节点轮询、startup probe inconclusive 不重试节点
- `nodes_cloud_actions_test.dart` — `confirmRepairCloudNode` 节点修复确认 + 活跃 SSH 路由先断开
- `cloud_provider_test.dart` — `redeployInstanceLabel` 唯一化 + `selectFastestConnectableInstance` 缓存
- `cloud_node_config_builder_test.dart` — sing-box 出站构造 + CDN-fronted vless+ws 变体
- `vultr_client_test.dart` / `digitalocean_client_test.dart` — REST 客户端的请求 shape 和错误归一化
- `profile_provider_test.dart` / `cloud_backup_test.dart` — Profile 存储与配置归一化、云备份恢复
- `subscription_parser_test.dart` — 订阅解析器

### Integration 测试

需要连接的 Android/iOS 设备或模拟器。运行：

```bash
cd mobile
/home/user/flutter/bin/flutter test integration_test/<file>.dart -d <device-id>
```

当前 `integration_test/` 覆盖：

- `smoke_test.dart` — 首页核心控件、API Key 对话框、设置导航、Profile 创建、空节点连接反馈
- `apikey_test.dart` — API Key 对话框保存后正确加载实例列表（`TestCloudProvider` 替身）
- `settings_navigation_flow_test.dart` — 设置页路由与返回
- `phone_interop_test.dart` — 设备互操作
- `vpn_dead_node_failure_test.dart` — 导入死节点订阅 → 连接失败 → 返回断开态并显示失败提示

### 未覆盖范围

以下场景目前不在自动化测试范围内，需要本地手测或后续构建专门的 mock 基础设施：

- **完整 connect 成功路径**：sing-box 端真实建立隧道、egress IP 校验。需要本地起 mock 代理服务器作 `PD_TEST_SUBSCRIPTION_URL` 上游。
- **真实云部署**：Vultr/DigitalOcean 创建实例的端到端流程，目前依赖手动验证（成本和耗时不适合 CI）。
- **iOS 真机集成测试**：`integration_test/` 目前只在 Android 设备上验证过；iOS 需要在嵌入 `VPNCore.framework` 后由本地 Xcode 跑。

## 已知改进方向

- 继续拆分 `features/nodes/nodes_screen.dart`
- 把工作台页拆成更清晰的导航结构
- 同步 README 与产品实际能力，避免文档再次漂移
