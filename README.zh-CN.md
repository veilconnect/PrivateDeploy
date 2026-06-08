# PrivateDeploy

[English](README.md) | **中文**

PrivateDeploy 一键开通经过安全加固的多协议 VPS 代理,并为所有访问它们的终端提供客户端:Vue 3 + Wails 桌面应用、Flutter 移动应用,以及一个独立的 Go HTTP API(用于无界面 / 多设备场景)。一份 user-data 引导脚本即可在单台 VPS 上拉起四种协议——Shadowsocks、Hysteria2、VLESS-Reality、Trojan——覆盖 Vultr、DigitalOcean 以及任何可 SSH 访问的主机(源码中还内置了 Contabo / Oracle / Hetzner / Linode / Scaleway / UpCloud 的静态目录,但未在发布版 UI 中暴露)。

> **移动端平台状态。** Android 已端到端跑通原生 VPN 服务。iOS 已接好 Swift 插件(`Runner/VpnPlugin.swift`)和 Packet Tunnel 扩展(`VPNExtension/PacketTunnelProvider.swift`),但所有原生 VPN 方法都以 `#if canImport(VPNCore)` 为前提;当 gomobile 构建的 `VPNCore.framework` 未嵌入 iOS 构建时,会返回明确的"unsupported"错误。因此 iOS 需要你先按 [`mobile/IOS_INTEGRATION.md`](mobile/IOS_INTEGRATION.md) 操作(gomobile framework 构建 + App Group + Network Extension 权限)才能控制 VPN。请把 iOS 当作 **beta / 需自行构建**,而非开箱即用。

单页拓扑图与模块映射见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 亮点

- **多协议栈** —— 一次部署 Shadowsocks、Hysteria2、VLESS-Reality(含 Reality 公钥 + short ID)和 Trojan。低内存套餐会自动回退到轻量的仅 Shadowsocks 配置。
- **凭据自动同步** —— 应用持久化每种协议的凭据(端口、密码、UUID、Reality 密钥),并在云面板中提供一键复制。
- **订阅集成** —— 生成的节点会被转换为 sing-box 兼容订阅并注入当前 profile,本地客户端便能在所有可用协议间轮换。
- **一键即走式开通** —— user-data 脚本直接在 VPS 上完成 Docker 安装、防火墙规则、systemd 服务、TLS 证书和健康检查。

## 一键安装(Linux)

```bash
curl -fsSL https://github.com/veilconnect/PrivateDeploy/raw/main/install.sh | bash
```

下载最新 release 安装到 `~/.local/bin/PrivateDeploy` 并注册应用菜单入口(重新执行即可升级)。Windows/macOS 请到 [Releases](https://github.com/veilconnect/PrivateDeploy/releases) 页下载安装器。

## 从源码构建

> 依赖:Node.js、pnpm、Go、Wails CLI。

```bash
# 如需要先安装 pnpm
npm install -g pnpm

# 构建前端 bundle
cd frontend
pnpm install --frozen-lockfile
pnpm build

# 构建桌面应用
cd ..
go install github.com/wailsapp/wails/v2/cmd/wails@latest
bash scripts/with_clean_runtime_data.sh wails build
```

## 使用云面板

1. 粘贴一个具备实例 + 防火墙权限的 Vultr API key 并保存。
2. 选择区域/套餐并部署 —— 高内存套餐会自动获得全部四种协议。
3. 开通完成后,展开节点行查看协议详情:
   - Shadowsocks 端口/密码及 ss:// 链接
   - Hysteria2 端口/密码及 hysteria2:// 链接
   - VLESS-Reality 的 UUID、公钥、short ID 及 vless:// 链接
   - Trojan 端口/密码及 trojan:// 链接
4. 用 *Copy All Links* 或各协议的复制按钮分享凭据。
5. 点 *Use Node* 把订阅注入当前 sing-box profile。

Reality 参数(公钥 + short ID)保存在 VPS 的 `/etc/privatedeploy/vless/reality.txt`,并在 UI 中展示,供需要手动配置的客户端使用。

## 更多文档

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) —— 系统拓扑、模块映射、部署流程。
- [`docs/MULTI-PROTOCOL-DESIGN.md`](docs/MULTI-PROTOCOL-DESIGN.md) —— 多协议部署流程深入解析。
- [`docs/MULTI-CLOUD-ARCHITECTURE.md`](docs/MULTI-CLOUD-ARCHITECTURE.md) —— 云厂商抽象与新增云的方法。
- [`docs/API_DESIGN.md`](docs/API_DESIGN.md) —— HTTP API 接口。

## 质量门禁(本地)

```bash
./scripts/quality_gate.sh
python3 e2e/run_cloud_ui_e2e.py
```

`quality_gate.sh` 会排除被 gitignore 的本地 `tmp/` 临时包,这样临时冒烟工具不会破坏仓库的测试门禁。

云 UI 回归脚本始终使用隔离的本地端口(`127.0.0.1:4174`),并拒绝 `7890`,以免干扰系统代理设置。

## 许可证

本项目以 GNU 通用公共许可证 v3.0(GPL-3.0)发布。详见 [LICENSE](LICENSE)。
