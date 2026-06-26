# PrivateDeploy 上线 GO/NO-GO 清单

> 适用范围：桌面端（Wails + Frontend）与 API 服务联动发布  
> 建议在发布日当天填写，形成可追溯记录。

## 1. 发布信息

- 发布版本：
- 发布定位：`Beta / Preview` / `Stable`
- 发布日期（北京时间）：
- 发布负责人：
- 值班负责人：
- 回滚负责人：
- 发布范围：
  - 桌面端：Windows / macOS / Linux
  - 移动端：Android / iOS
  - API 服务：公开 / 内部 / 不发布

### 推荐定位

在桌面端、Android、API 服务已通过质量门禁，但 iOS、真实云厂商联调、安装包签名与敏感信息清理尚未完成前，建议以 `Beta / Preview` 发布，不建议标记为稳定版。

Beta / Preview 发布说明应明确：

- 当前版本适合技术用户和早期试用。
- 云厂商创建、销毁、部署链路已覆盖冒烟测试，但仍需要真实环境反馈。
- iOS 如未完成真机验证和 VPNCore 嵌入，不列为正式支持平台。
- 生产使用前需要用户自行保管云厂商 API Key、SSH 密钥和节点凭据。

## 2. P0 阻断项（任一未通过即 NO-GO）

1. CI 质量门禁全部通过（必填）
   - `bash scripts/check_versions.sh`
   - `go test ./...`
   - `cd api && go test ./...`
   - `cd frontend && pnpm run type-check`
   - `cd frontend && pnpm run lint:ci`
   - `cd frontend && pnpm vitest run`
   - `cd frontend && pnpm run build`
   - `cd mobile && flutter test`
   - `cd mobile && flutter analyze --no-fatal-infos`
   - `python3 e2e/run_cloud_ui_e2e.py`
2. 真实云厂商联调完成（至少覆盖发布说明中声明支持的厂商）
   - Vultr：
     - 创建节点
     - 等待 SSH 可用
     - 部署代理服务
     - 获取并复制协议链接
     - 删除节点
   - DigitalOcean：
     - 创建节点
     - 等待 SSH 可用
     - 部署代理服务
     - 获取并复制协议链接
     - 删除节点
   - Hetzner / 其他厂商（如本次声明支持）：
     - 创建节点
     - 部署代理服务
     - 删除节点
3. 云节点和协议链路冒烟完成
   - 创建节点
   - 切换服务商
   - 手动新增节点
   - 协议链接导入（含 sni / insecure）
   - Shadowsocks 连接可用
   - Hysteria2 连接可用
   - VLESS / Trojan 如发布说明声明支持，则连接可用
   - 复制 `IPv4:port` 和分享链接不会缺字段
   - 删除节点
4. 桌面端核心体验检查通过
   - 首页可直接看到本地代理端口（Mixed / HTTP / SOCKS）
   - 端口复制结果正确：
     - Mixed：`127.0.0.1:<port>`
     - HTTP：`http://127.0.0.1:<port>`
     - SOCKS：`socks5://127.0.0.1:<port>`
   - 系统代理开关状态与实际系统设置一致
   - TUN / 系统代理失败时有明确错误提示
   - 云节点列表能清楚显示协议、端口、传输类型
5. 移动端发布范围确认
   - Android 如列入正式发布：安装、启动、VPN 授权、连接、断开均通过真机测试
   - iOS 如列入正式发布：VPNCore.framework 已嵌入，签名、权限、真机连接均通过
   - iOS 如未完成上述验证：发布说明必须标记为 Beta / 暂不正式支持
6. 安全配置检查通过
   - 历史泄露过的云厂商 API Key 已确认轮换
   - 发布前运行密钥扫描，确认无 API Key、私钥、token、节点密码泄露
   - `JWT_SECRET` 已在生产环境固定配置
   - `INITIAL_ADMIN_PASSWORD` 已在生产环境固定配置
   - 凭据不在日志、截图、发布说明中泄露
   - E2E 截图、报告、日志不包含真实 IP、密钥、密码、订阅链接
7. 安装包与分发检查通过
   - Windows 安装包可安装、启动、卸载
   - macOS DMG 可打开、拖拽安装、启动
   - Linux DEB / RPM 可安装、启动、卸载
   - 发布包版本号与 git tag、`VERSION`、前端 package、移动端版本一致
   - 发布包来自同一个 commit/tag
   - 发布说明列出校验和（SHA256）
8. 回滚预案可执行并已演练
   - 回滚包可用
   - 回滚步骤在 10 分钟内可完成
   - 回滚后核心健康检查通过

## 3. P1 非阻断项（建议通过）

1. 24 小时稳态观察通过
2. 错误告警规则已启用（登录失败率、创建失败率、API 5xx）
3. 发布说明已同步到团队文档
4. 发布说明包含“已知问题”
   - iOS 支持状态
   - 已验证云厂商列表
   - 未验证云厂商列表
   - 桌面端系统代理 / TUN 的平台差异
   - 用户需要自行准备的云厂商 API Key、SSH Key、域名或证书
5. 新用户最短路径可完成
   - 第一次启动
   - 填入云厂商凭据
   - 创建节点
   - 查看端口
   - 复制代理地址
   - 删除节点
6. 竞品体验对齐检查
   - 首页像 Clash 一样能一眼看到本地代理端口
   - 节点详情像 3x-ui / Marzban 一样能看到协议、端口、分享链接
   - 自建流程像 Outline / Amnezia 一样尽量少暴露底层复杂度

## 4. 上线后观察指标（建议前 30 分钟每 5 分钟一次）

1. 登录成功率
2. 云节点创建成功率
3. 节点删除成功率
4. API `/api/v1/health` 可用性
5. UI 关键页面控制台错误数量

## 5. 发布决策

- 结论：`GO` / `NO-GO`
- 决策时间（北京时间）：
- 决策人：
- 备注：

## 6. 回滚步骤模板

1. 暂停新发布流量或停止新版本分发。
2. 切回上一稳定版本（记录 commit/tag）。
3. 重启服务并执行健康检查：
   - API：`/api/v1/health`
   - UI：关键页面可打开、创建/删除最小冒烟
4. 验证关键链路恢复（登录、创建、删除）。
5. 发布回滚公告，并附根因排查链接。
