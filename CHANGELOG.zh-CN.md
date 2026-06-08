# Changelog

[English](CHANGELOG.md) | **中文**

本变更日志依据 git 历史回填了发布说明,并记录下一条尚未发布的工作主线。

本项目经历了两个截然不同的产品阶段:

- `GUI.for.SingBox`:一个桌面 sing-box GUI 客户端
- `PrivateDeploy`:一个桌面 + 云自动化产品,目前在 `main` 上已带有移动端配套应用和独立的 API 模块

## [Unreleased]

- 暂无未发布的说明。

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
