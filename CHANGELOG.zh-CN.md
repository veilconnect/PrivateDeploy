# Changelog

[English](CHANGELOG.md) | **中文**

本变更日志依据 git 历史回填了发布说明,并记录下一条尚未发布的工作主线。

本项目经历了两个截然不同的产品阶段:

- `GUI.for.SingBox`:一个桌面 sing-box GUI 客户端
- `PrivateDeploy`:一个桌面 + 云自动化产品,目前在 `main` 上已带有移动端配套应用和独立的 API 模块

## [Unreleased]

- 暂无未发布的说明。

## [2.0.14] - 2026-06-30

### 修复
- **VLESS 连不上(Reality 握手目标)**:VLESS-Reality 的 `server_name` 默认
  `www.microsoft.com`,其多 CDN 地域漂移源站(Azure Front Door/Akamai)转发的
  TLS 握手在边缘间不一致,sing-box 判 `REALITY: processed invalid connection`
  → 只有 VLESS 连不上(Hysteria/Trojan 仅把该域名当 SNI 标签)。VLESS 改用专属的
  单源稳定目标池(永不含 microsoft),与 Trojan/Hysteria 的 SNI 池解耦,并在请求时
  探测可达目标。存量节点需重新部署以选用新目标。
- **蜂窝下配了 CDN 仍连不上(sing-box 1.12 配置)**:客户端内核升到 sing-box
  1.12.x 后,云节点与订阅配置生成器仍输出被 1.12.0 移除的老写法
  `geoip: ["private"]`,导致整份配置解析失败 → VPN 起不来,尤其是蜂窝依赖的
  CDN-front 路径。改为 `ip_is_private: true`。

### 变更
- **前向兼容 sing-box 1.13**:把已弃用的 `dns`/`block` 特殊出站迁移为路由规则
  action(`hijack-dns`;未被引用的 `block` 出站直接删除),涉及云节点与订阅配置
  生成器。这些特殊出站在 sing-box 1.13 移除;实测 1.11.0 与 1.12.12 在不设弃用
  开关时均通过。

## [2.0.13] - 2026-06-29

### 变更
- **内部重构(无行为变化)**:将云 provider 间重复的辅助函数收敛到共享的
  `internal/provutil` 包(Vultr / DigitalOcean / SSH / 静态 catalog 四端);把独立
  HTTP API 的数据模型(`Subscription`、`Profile`、VPN 状态/统计 DTO)抽到专门的
  `api/models` 包;并把移动端过大的 `cloud_provider.dart` 中的顶层探测/记录辅助
  函数拆到聚焦的 `part` 文件。

### 测试
- **更强的跨端防漂移守卫**:Go↔Dart parity 测试现在断言 sing-box 压缩包的
  SHA-256 pin 在两端逐字节一致(不再只比版本号),保持默认 SNI 伪装域名同步,
  并检查更多 SSH 加固指令在两端部署脚本中都存在。

## [2.0.12] - 2026-06-24

### 新增
- **DigitalOcean 节点恢复**:本地记录丢失时(换设备、CLI 创建的节点、状态损坏)
  现可恢复 DO 节点凭据,与 Vultr 对齐。由于 DO API 既读不到 droplet 的 user-data、
  也不能给运行中的 droplet 加 SSH key,实现采用托管 key:首次使用生成 ed25519,
  公钥注册到 DO 账户(名 `privatedeploy-managed`),私钥存 OS keyring,并挂到每个
  新建 DO droplet 上;恢复时 SSH 进 droplet 解析 cloud-init user-data。已真机
  端到端验证。
  - **安全取舍(仅 DO)**:这会往你的 DigitalOcean 账户加一把常驻、可 root 的 SSH
    key,并挂到所有 PrivateDeploy droplet 上。Vultr 不需要这把 key(经 API 恢复)。
    恢复读取使用 trust-on-first-use host key。

### 变更
- 把 user-data 恢复解析器抽到共享 `cloud` 包,Vultr 与 DigitalOcean 复用同一实现。

## [2.0.11] - 2026-06-24

### 安全
- **Cloudflare CDN token 改走 OS keyring**:桌面 CDN token 是最后一个仍以明文写入
  `data/cdn/config.json` 的密钥(云厂商 API key 和节点记录加密密钥早已走 keyring)。
  现接入同一 secret store;旧版明文 token 在读取时自动迁移。
- **插件信任边界加固(低破坏)**:远程插件代码只允许经 HTTPS 从白名单域名拉取,
  并按 SHA-256 对插件代码做 pin(首次信任);更新漂移或磁盘篡改需重新确认才运行。
- **手机端部署对齐桌面加固**:此前从手机部署的节点缺少桌面的 sing-box 下载校验和/
  回退、SSH 加固、fail2ban、SSH 限速。现两端一致,并统一 sing-box 版本
  (1.12.12,回退 1.11.0)。

### 变更
- **云调用加超时与取消**:桌面 bridge 的云操作改为从 App 生命周期派生 context
  (关闭即取消)并加按操作超时,替代无界的 `context.Background()`。
- 抽出共享 `EnsureManagedTLSDefaults`,4 个云 provider 不再各自漂移协议默认值;
  新增跨端部署脚本 drift 守卫测试。

### 文档
- `API_DESIGN.md`:删除已从 API 移除的认证/VPN 端点章节,并指向权威来源
  (Gin 路由 + `openapi.yaml`)。

## [2.0.10] - 2026-06-24

### Tests
- **安全存储 fail-closed 回归测试**:为 `getSecureString` 的旧版明文迁移路径补了一条
  回归用例——当 keystore 不可用时,应返回已落盘的旧版明文密钥并保留明文 mirror
  以便下次重试,而不是把用户锁在自己的凭据之外。fail-closed 契约约束的是「写入
  新明文」,而非销毁已落盘的数据;该测试可防止日后有人误把它「改成返回 null」
  从而误伤存量用户。

## [2.0.9] - 2026-06-23

### Fixed
- **CDN Worker 1101(连接失效根因)**:部署 Worker 的 `compatibility_date` 固定在 2024-09-23,
  Cloudflare 2026 年初运行时变更后导致 `import { connect } from 'cloudflare:sockets'` 模块加载失败,
  Worker 恒返回 CF 1101 → CDN 中转路径全失效 → 蜂窝下被运营商不可达的节点无法经 CDN 备用路径。
  移动端 `_kCompatDate` 与桌面 `bridge/cdn` `workerCompatDate` 一并升级到 2026-06-01。

### Added
- **部署对话框区域可达性**:创建节点时,区域下拉从本机当前网络实测各 Vultr 区域延迟/可达性,
  按延迟排序、自动预选最快可达区域、标注「不可达」,并显示 可达性风险等级图标(🟢🟡🟠🔴);
  结果持久化以便冷启动即时显示。桌面端同样持久化区域延迟结果。
- **CDN 重新部署与自愈**:已部署节点新增「重新部署」按钮(就地覆盖,免去先删再部署);
  蜂窝自动部署在检测到 Worker 损坏时自动重新部署;新增部署健康判定。

## [2.0.0] - 2026-04-03

### Added

- 面向 cloud、profile、subscription、system、VPN 以及 websocket 工作流的独立 REST API 模块。
- 跨平台移动应用,集成 Android/iOS VPN、云节点管理、诊断、备份/恢复以及路由控制。
- 移动端分流路由控制,内置 CN 规则集、自定义规则,以及 Android 上基于应用的 direct/proxy 路由。
- 移动端 VPN 诊断,提供最近的路由决策与出口 IP 探测。
- 面向移动端的真实下载云基准测试流程,并辅以轻量级的快速测试延迟选择。
- 扩展的云服务商体系及配套基础设施,包括服务商目录模块、云密钥存储、健康监控、推荐辅助以及文件系统服务。
- 用于移动端构建、测试与发布自动化的额外 CI/CD 工作流。

### Changed

- 桌面端云管理被重构为更模块化的 store 架构,具备更清晰的历史记录、实例同步、备份、智能路由以及展示层。
- 桌面端的启动、系统代理、运行时初始化(seeding)以及恢复流程在 Linux、Windows 以及发布打包中得到加固。
- 移动端的工作区、设置、对话框、区块以及操作流程被拆分为更小的模块,并扩大了单元测试与集成测试覆盖率。
- 移动端节点选择现在会优先选用最近的基准测试优胜者,并可从顶层的 `Connect` 操作中复用它们。

### Fixed

- 桌面端与移动端在多处云部署、同步以及启动方面的竞态条件。
- Windows 运行时初始化(seeding)以及内置 core 二进制文件的就绪状态不匹配问题。
- 移动端 VPN 冲突处理、Android DNS / Private DNS 兼容性、诊断响应性、连接状态 UX,以及订阅导入 / 备份恢复的边界情况。
- 云基准测试的准确性,以及按节点 / 按协议的选择行为。
- 围绕凭据、启动恢复、运行时环境处理以及部署加固的安全性与健壮性问题。

## [1.10.1] - 2025-11-04

首个正式的 `PrivateDeploy` 发布线。

### Added

- 云服务商基础设施,以及桌面应用中首个完整的云管理界面。
- 以 Vultr 为中心、面向 Shadowsocks、Hysteria2、VLESS-Reality 以及 Trojan 的加固多协议部署工作流。
- 部署进度时间线、云节点自动应用、自动启动改进,以及围绕 provider/plan/region 选择的更佳云 UX。
- 针对仓库重命名以及多平台构建自动化的 GitHub Actions 更新。

### Changed

- 项目名称、仓库引用以及品牌从 `VeilDeploy` / `GUI.for.SingBox` 迁移为 `PrivateDeploy`。
- README 与面向用户的文档被围绕云端节点部署重写,而非以往那种通用的本地 GUI 叙事。

### Fixed

- 启动顺序,使云节点在 kernel 启动前先被应用。
- 切换 plan / region 时的启动卡顿以及陈旧的 provider 状态。
- 针对在配置生命周期后期才获得 IP 的节点的重试逻辑。
- 围绕云服务商选择与部署显示的若干 UX 问题。

## [1.10.0] - 2025-09-22

PrivateDeploy 之前桌面线中的最后一个大版本发布。

### Added

- 动态 i18n 加载支持。
- 更细粒度的 kernel 启动 / 停止状态管理。
- 针对 switches、dropdowns、selects 以及 controller 设置的无障碍性与可用性改进。
- profile 路由控制,包括 `route_exclude_address` 以及默认的 ICMP direct 规则处理。
- 可选的 debug 无动画设置。

### Changed

- 计划任务处理从此前基于 Go 的路径迁移出来。
- 桌面端 UI 基础组件、选择控件以及启动生命周期逻辑被重构,以获得更好的稳定性。
- 发布构建 / 产物流程被精简。

### Fixed

- core 停止状态处理以及主页视图渲染。
- core-branch 逻辑中因拉取过多发布条目而产生的内存压力。
- profile 切换时的启动顺序以及陈旧的 kernel 日志行为。
- 递归表格渲染问题以及若干 UI 交互回归。

## [1.9.9] - 2025-08-27

原 `GUI.for.SingBox` 线中的后期维护版本发布。

### Changed

- 在更大规模的 `v1.10.x` 桌面重构线之前,对 bridge 与前端环境做的小幅调整。

### Notes

- 此版本仍属于旧的通用 sing-box 桌面 GUI 时代,并不反映后来的 `PrivateDeploy` 云自动化方向。
