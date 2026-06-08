# 跨平台适配计划

[English](CROSS_PLATFORM_ADAPTATION_PLAN.md) | **中文**

## 目标

使 PrivateDeploy 在 Linux、Windows 和 macOS 上保持稳定且行为一致,涵盖:

- 桌面端启动
- 原生 webview 渲染
- 系统代理管理
- 托盘集成
- 开机自启
- 云端部署 UI 流程
- 内核启停与配置应用流程

## 现状

已修复:

- 由不安全的 `webviewGpuPolicy` 默认值及迁移导致的 Linux 空白窗口

仍需平台加固:

- 原生控件交互一致性
- 平台特有的系统集成行为
- 在所有目标平台上的真实桌面端 E2E 回归

## 工作流

### 1. 桌面运行时安全

目的:
在 UI 逻辑运行之前,先行阻止平台特有的启动与渲染失败。

文件:

- `main.go`
- `bridge/bridge.go`
- `bridge/types.go`
- `frontend/src/stores/appSettings.ts`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`

任务:

1. 按操作系统为 webview/GPU 策略定义平台安全的默认值。
2. 为已弃用或不安全的取值添加启动迁移规则。
3. 扩展启动诊断,记录:
   - 操作系统
   - 显示会话类型
   - webview GPU 策略
   - 应用版本
4. 添加平台特有的启动预检:
   - Linux:X11/Wayland 可达性
   - Windows:WebView2 运行时可用性
   - macOS:相关权限与运行时检查

验收标准:

- 应用在受支持的桌面环境中启动时不出现白屏/空白窗口。
- 无效的旧设置在无需用户干预的情况下自动迁移。
- 启动失败时产生可操作的错误,而非静默的破损窗口。

### 2. 系统代理生命周期

目的:
使代理行为安全、可逆且符合平台规范。

文件:

- `frontend/src/stores/env.ts`
- `frontend/src/stores/kernelApi.ts`
- `frontend/src/utils/helper.ts`
- `frontend/src/App.vue`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- `bridge/` 下的平台特有 bridge/进程辅助代码

任务:

1. 将代理操作拆分到平台能力层,而非隐式的共享逻辑。
2. 为以下场景保证备份/恢复语义:
   - 首次启用
   - 正常停止
   - 崩溃恢复
   - 应用升级/重启
3. 跨 HTTP/SOCKS 变体统一应用托管代理的检测。
4. 向日志与 UI 添加显式的代理状态诊断。
5. 为以下情况添加回归测试:
   - 已存在系统代理
   - 应用设置代理
   - 应用意外退出
   - 代理被恢复

验收标准:

- 启用代理永远不会在没有备份的情况下破坏已有的用户代理。
- 停止内核或应用时,可靠地恢复先前的代理状态。
- 崩溃恢复不会遗留陈旧的应用托管代理。

### 3. 托盘与原生外壳集成

目的:
使托盘、菜单及原生外壳功能在各操作系统间保持一致。

文件:

- `bridge/tray.go`
- `frontend/src/utils/tray.ts`
- `frontend/src/utils/command.ts`
- `frontend/src/components/TitleBar.vue`

任务:

1. 审查各平台的托盘支持差异:
   - 图标渲染
   - 菜单点击行为
   - 窗口显示/隐藏
2. 在托盘不可用或不稳定时定义优雅降级。
3. 验证菜单的一致性,涵盖:
   - 内核操作
   - 代理操作
   - 配置分组
   - 重启/退出
4. 为托盘触发的操作添加平台特有的冒烟测试。

验收标准:

- 托盘在每个目标操作系统上要么正常工作,要么干净地降级。
- 托盘操作与应用内操作一致,功能上不发生偏移。

### 4. 开机自启与权限

目的:
使启动行为显式且符合平台规范。

文件:

- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- `frontend/src/utils/others.ts`
- `frontend/src/utils/helper.ts`
- `main.go`
- `bridge/` 下的平台特有启动辅助代码

任务:

1. 用按平台实现替换以 Windows 为中心的启动假设。
2. 支持并验证:
   - Windows 计划任务 / 启动项
   - Linux 桌面自启
   - macOS 登录项 / launch agent
3. 区分「需要管理员权限」「需要重启」与「此操作系统支持」。
4. 在 UI 中清晰地呈现不支持的功能,而非隐藏含混的行为。

验收标准:

- 每个操作系统要么干净地支持自启,要么清晰地报告不支持的状态。
- 设置页反映实际的平台能力,而非通用的开关。

### 5. 原生 UI 控件一致性

目的:
减少真实桌面窗口中与操作系统相关的交互偏移。

文件:

- `frontend/src/views/CloudView/index.vue`
- `frontend/src/components/Dropdown/index.vue`
- `frontend/src/components/Input/index.vue`
- `frontend/src/components/Menu/index.vue`
- `frontend/src/components/Modal/index.vue`
- `frontend/src/components/Tips/index.vue`

任务:

1. 审查桌面运行时中下拉框、模态框、输入框及键盘焦点的行为。
2. 修复原生交互的边缘情况:
   - 下拉框打开/关闭行为
   - 键盘选择
   - 失焦
   - 覆盖层堆叠
3. 验证 HiDPI 下指针命中目标与坐标的正确性。
4. 为以下流程添加原生桌面 UI 冒烟流程:
   - 切换云服务商
   - 打开模态框
   - 保存配置
   - 应用节点

验收标准:

- 关键控件在 Linux、Windows 和 macOS 上行为一致。
- 服务商切换与节点应用可通过鼠标和键盘完成。

### 6. 云工作流回归

目的:
确保主要部署工作流在桌面端与基于浏览器的测试框架中行为一致。

文件:

- `frontend/src/views/CloudView/index.vue`
- `frontend/src/stores/cloud.ts`
- `bridge/cloud_bridge.go`
- `e2e/run_cloud_ui_e2e.py`
- `tmp/pdcloudctl/main.go`

任务:

1. 将基于浏览器的云回归保留为快速的功能基线。
2. 添加原生桌面云冒烟流程,涵盖:
   - 打开 Deploy 页面
   - 切换服务商
   - 刷新节点
   - 将节点应用到配置
3. 为协议选择行为添加断言:
   - 降级的协议被排除在托管订阅之外
   - 存在每节点最佳协议自动分组
4. 验证服务商切换正确保留各服务商特有的配置。

验收标准:

- 云页面在模拟浏览器回归与原生桌面回归中均可工作。
- DO 节点在健康时仍可使用 `Hysteria2`。
- 具有降级 `Hysteria2` 的 Vultr 节点被自动排除。

### 7. 平台能力层

目的:
停止将操作系统检查散布到 UI 与 stores 中。

文件:

- `frontend/src/stores/env.ts`
- `frontend/src/stores/appSettings.ts`
- `frontend/src/views/SettingsView/components/GeneralSettings.vue`
- `bridge/types.go`
- `bridge/bridge.go`

任务:

1. 引入由 bridge/env 返回的统一能力模型:
   - traySupported
   - systemProxySupported
   - startupSupported
   - adminElevationSupported
   - configurableWebviewGpuPolicy
2. 由能力驱动 UI 可见性与文案,而非硬编码的操作系统分支。
3. 将平台功能策略集中到一处。

验收标准:

- 设置 UI 反映真实能力,而非猜测的平台假设。
- 新增平台特有分支只在单一层内添加,而非散落多处。

### 8. 测试矩阵

目标环境:

1. Linux X11
2. Linux Wayland
3. Windows 10
4. Windows 11
5. macOS Intel
6. macOS Apple Silicon

每平台必测用例:

1. 应用启动时不出现空白窗口。
2. 设置变更在重启后保留。
3. Deploy 页面可打开。
4. 云服务商正确切换。
5. 节点列表刷新可用。
6. 应用节点更新当前配置。
7. 内核可启动和停止。
8. 系统代理可设置、清除并恢复。
9. 应用退出时不遗留陈旧状态。

## 交付顺序

### 阶段 1

- 桌面运行时安全
- 平台能力层
- 系统代理生命周期加固

### 阶段 2

- 托盘与开机自启集成
- 原生 UI 控件一致性

### 阶段 3

- 原生桌面云回归
- 完整的跨平台测试矩阵

## 当前优先级

按以下顺序实现:

1. 平台能力层
2. 系统代理生命周期回归覆盖
3. 原生 CloudView 控件一致性,尤其是服务商下拉框交互
