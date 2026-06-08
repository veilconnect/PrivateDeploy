# PrivateDeploy 移动端开发计划

[English](MOBILE_DEVELOPMENT_PLAN.md) | **中文**

## 📋 项目概览

**目标：** 开发 Android 和 iOS 移动应用，具备桌面版的**全部功能**

**架构策略：** 混合方案
- **桌面版：** 保留 Wails（Windows/macOS/Linux）
- **移动版：** 新开发 Flutter 应用（Android/iOS）
- **后端：** 共享 Go REST API 服务

---

## 🎯 当前功能清单（需要在移动端实现）

### 核心功能模块

| 模块 | 功能描述 | 移动端实现难度 |
|------|----------|--------------|
| **HomeView** | 概览仪表盘、状态显示 | ⭐ 简单 |
| **CloudView** | 云服务器管理（Vultr/DigitalOcean） | ⭐⭐ 中等 |
| **ProfilesView** | 配置文件管理（DNS/路由/入站/出站） | ⭐⭐⭐ 复杂 |
| **SubscribesView** | 订阅管理 | ⭐⭐ 中等 |
| **RulesetsView** | 规则集管理 | ⭐⭐ 中等 |
| **PluginsView** | 插件系统 | ⭐⭐⭐ 复杂 |
| **ScheduledTasksView** | 定时任务 | ⭐⭐ 中等 |
| **SettingsView** | 应用设置 | ⭐ 简单 |
| **系统托盘** | 后台运行、快速切换 | ⭐⭐⭐ 移动端需特殊处理 |
| **VPN/代理内核** | sing-box 集成 | ⭐⭐⭐⭐ 最复杂 |

### 后端功能

- ✅ 云服务商管理（Vultr、DigitalOcean）
- ✅ 服务器CRUD操作
- ✅ 区域/套餐查询
- ✅ 配置文件管理
- ✅ 网络接口查询
- ✅ 通知系统
- ✅ 文件I/O操作
- ✅ 进程管理
- ✅ MMDB地理位置

---

## 🔧 技术选型分析

### 方案对比

| 技术栈 | 优势 | 劣势 | 推荐度 |
|--------|------|------|--------|
| **Flutter** | • 单代码库双平台<br>• 性能接近原生<br>• UI 组件丰富<br>• Go 集成良好（gomobile） | • 包体积较大（~20MB） | ⭐⭐⭐⭐⭐ **强烈推荐** |
| **React Native** | • Web 技术栈<br>• 前端可复用部分代码<br>• 社区庞大 | • Go 集成困难<br>• 需要 Native Module 桥接 | ⭐⭐⭐ 可选 |
| **Kotlin Multiplatform** | • 纯原生性能<br>• 类型安全 | • 需要分别开发 Android/iOS<br>• 学习曲线陡峭 | ⭐⭐ 不推荐 |

### ✅ 最终选择：**Flutter**

**理由：**
1. **Go 集成** - 可以用 `gomobile` 将 Go 代码编译为移动库
2. **性能** - 接近原生性能，适合 VPN 应用
3. **开发效率** - 单代码库支持 Android 和 iOS
4. **sing-box 支持** - sing-box 官方有移动端集成案例

---

## 🏗️ 新架构设计

### 架构图

```
┌─────────────────────────────────────────────────────┐
│                    客户端层                          │
├──────────────────┬──────────────────────────────────┤
│  桌面客户端       │         移动客户端                │
│  (Wails)         │         (Flutter)                │
│                  │                                   │
│  • Windows       │  • Android 7.0+                  │
│  • macOS         │  • iOS 12.0+                     │
│  • Linux         │                                   │
└──────────────────┴──────────────────────────────────┘
         │                          │
         │                          │
         ▼                          ▼
┌─────────────────────────────────────────────────────┐
│              REST API 服务器 (Go)                    │
│                                                      │
│  • HTTP/HTTPS 接口                                   │
│  • JWT 认证                                          │
│  • WebSocket 实时通知                                │
│  • 云服务商集成                                      │
│  • 配置管理                                          │
│  • 数据持久化                                        │
└─────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│              数据存储层                              │
│                                                      │
│  • SQLite (本地)                                    │
│  • 文件系统 (配置/日志)                              │
└─────────────────────────────────────────────────────┘
```

---

## 📱 移动端特殊功能实现

### 1. VPN 核心功能（最关键）

#### Android 实现
```dart
// 使用 Android VpnService
class SingBoxVpnService {
  // 通过 Platform Channel 调用 Go sing-box 库
  static const platform = MethodChannel('com.privatedeploy/vpn');

  Future<void> startVpn(String configPath) async {
    await platform.invokeMethod('startVpn', {'config': configPath});
  }

  Future<void> stopVpn() async {
    await platform.invokeMethod('stopVpn');
  }
}
```

**实现方式：**
- Go sing-box 通过 `gomobile` 编译为 `.aar` 库
- Android VpnService 调用 Go 库
- 需要申请 `BIND_VPN_SERVICE` 权限

#### iOS 实现
```dart
// 使用 Network Extension
class SingBoxNetworkExtension {
  // 通过 Platform Channel 调用 Go sing-box 库
  Future<void> startTunnel(String configPath) async {
    await platform.invokeMethod('startTunnel', {'config': configPath});
  }
}
```

**实现方式：**
- Go sing-box 通过 `gomobile` 编译为 `.framework`
- 使用 Network Extension (NEPacketTunnelProvider)
- 需要申请 Network Extension 权限

### 2. 后台运行

#### Android
- 使用 Foreground Service（常驻通知）
- WorkManager 定时任务
- 电池优化白名单引导

#### iOS
- Background Modes（VPN 自动保持后台）
- Silent Push Notifications
- App Refresh

### 3. 系统托盘替代方案

移动端没有系统托盘，采用以下方案：

- ✅ **快速设置磁贴**（Android Quick Settings Tile）
- ✅ **通知常驻**（显示连接状态）
- ✅ **Widget 小部件**（iOS 14+、Android）
- ✅ **3D Touch / Haptic Touch 快捷菜单**（iOS）

---

## 🚀 开发路线图

### Phase 1: 基础架构（4-6 周）

**Week 1-2: 后端 API 服务**
- [ ] 重构现有 Go 代码，分离为独立 HTTP 服务
- [ ] 实现 JWT 认证
- [ ] 设计 RESTful API 接口
- [ ] WebSocket 实时通知
- [ ] API 文档（Swagger）

**Week 3-4: Flutter 项目初始化**
- [ ] 创建 Flutter 项目结构
- [ ] 配置 Android/iOS 构建环境
- [ ] 集成 sing-box Go 库（gomobile）
- [ ] 实现基础 VPN 功能（Android VpnService）
- [ ] 实现基础 VPN 功能（iOS Network Extension）

**Week 5-6: 核心功能开发**
- [ ] 用户界面框架（Material Design / Cupertino）
- [ ] 状态管理（Provider / Riverpod / Bloc）
- [ ] 网络请求层（Dio + Retrofit）
- [ ] 本地存储（Hive / SQLite）

### Phase 2: 功能实现（8-10 周）

**Week 7-8: 首页 & 连接管理**
- [ ] HomeView - 仪表盘 UI
- [ ] 连接状态显示
- [ ] 一键连接/断开
- [ ] 流量统计图表
- [ ] 延迟测试

**Week 9-10: 云服务器管理**
- [ ] CloudView - 服务器列表
- [ ] 创建服务器向导
- [ ] 区域/套餐选择器
- [ ] 服务器详情页
- [ ] 销毁服务器确认

**Week 11-12: 配置管理**
- [ ] ProfilesView - 配置列表
- [ ] 配置编辑器（简化版 JSON）
- [ ] 入站/出站配置
- [ ] DNS 配置
- [ ] 路由规则配置

**Week 13-14: 订阅 & 规则集**
- [ ] SubscribesView - 订阅管理
- [ ] 订阅更新/导入
- [ ] RulesetsView - 规则集管理
- [ ] 规则编辑器

**Week 15-16: 高级功能**
- [ ] PluginsView - 插件系统
- [ ] ScheduledTasksView - 定时任务
- [ ] SettingsView - 应用设置
- [ ] CommandView - 命令行界面（可选）

### Phase 3: 移动端优化（4 周）

**Week 17-18: 平台特性**
- [ ] Android Quick Settings Tile
- [ ] iOS Widget（Today Extension）
- [ ] 3D Touch 快捷菜单
- [ ] 通知管理
- [ ] 分享扩展（导入配置）

**Week 19-20: 性能优化**
- [ ] 网络优化（HTTP/2、连接池）
- [ ] 内存优化
- [ ] 电池优化
- [ ] 启动速度优化
- [ ] 包体积优化

### Phase 4: 测试 & 发布（4 周）

**Week 21-22: 测试**
- [ ] 单元测试
- [ ] 集成测试
- [ ] UI 自动化测试
- [ ] Beta 测试（TestFlight / Google Play Beta）
- [ ] Bug 修复

**Week 23-24: 发布准备**
- [ ] 应用商店截图
- [ ] 应用描述文案
- [ ] 隐私政策
- [ ] Google Play 上架
- [ ] App Store 审核提交

---

## 📦 技术栈详细清单

### 移动端（Flutter）

```yaml
dependencies:
  # 核心
  flutter:
    sdk: flutter

  # UI 组件
  flutter_screenutil: ^5.9.0  # 屏幕适配
  flutter_svg: ^2.0.9          # SVG 图标

  # 状态管理
  provider: ^6.1.1             # 或 riverpod / bloc

  # 网络
  dio: ^5.4.0                  # HTTP 客户端
  retrofit: ^4.0.3             # REST API
  web_socket_channel: ^2.4.0   # WebSocket

  # 本地存储
  hive: ^2.2.3                 # NoSQL 数据库
  hive_flutter: ^1.1.0
  shared_preferences: ^2.2.2   # Key-Value 存储

  # VPN 核心
  flutter_vpn: ^1.0.0          # VPN 服务封装

  # 图表
  fl_chart: ^0.66.0            # 流量统计图表

  # 工具
  intl: ^0.18.1                # 国际化
  logger: ^2.0.2               # 日志
  path_provider: ^2.1.1        # 文件路径
  permission_handler: ^11.1.0  # 权限管理

  # 其他
  flutter_local_notifications: ^16.3.0  # 本地通知
  package_info_plus: ^5.0.1             # 应用信息
```

### 后端（Go REST API）

```go
// 主要依赖
require (
    github.com/gin-gonic/gin v1.10.0           // Web 框架
    github.com/golang-jwt/jwt/v5 v5.2.0        // JWT 认证
    github.com/gorilla/websocket v1.5.1        // WebSocket
    gorm.io/gorm v1.25.5                       // ORM
    gorm.io/driver/sqlite v1.5.4               // SQLite
    github.com/swaggo/swag v1.16.2             // API 文档
    github.com/sagernet/sing-box v1.8.0        // VPN 核心
)
```

---

## 🔐 安全考虑

### API 安全
- ✅ JWT Token 认证
- ✅ HTTPS 加密传输
- ✅ API Rate Limiting
- ✅ 请求签名验证

### 移动端安全
- ✅ 密钥存储（Keychain / KeyStore）
- ✅ SSL Pinning（防中间人攻击）
- ✅ 代码混淆（R8 / Obfuscation）
- ✅ Root/越狱检测

### VPN 安全
- ✅ 配置文件加密
- ✅ DNS 泄漏防护
- ✅ IPv6 泄漏防护
- ✅ Kill Switch（断网保护）

---

## 📊 预估工作量

| 阶段 | 工作量 | 人员配置 |
|------|--------|----------|
| **Phase 1: 基础架构** | 6 周 | 1 Go 后端 + 1 Flutter 开发 |
| **Phase 2: 功能实现** | 10 周 | 2 Flutter 开发 + 1 Go 后端 |
| **Phase 3: 移动端优化** | 4 周 | 2 Flutter 开发 |
| **Phase 4: 测试发布** | 4 周 | 全员 |
| **总计** | **24 周（6 个月）** | **2-3 人** |

---

## 💰 成本估算

### 开发成本
- **人员成本：** 2-3 名开发者 × 6 个月
- **开发工具：** Android Studio、Xcode、GitHub（免费或现有）

### 基础设施
- **API 服务器：** 云服务器 $10-50/月
- **CDN/存储：** $5-20/月
- **测试设备：** Android 测试机、iPhone 测试机

### 应用商店
- **Google Play：** $25 一次性注册费
- **App Store：** $99/年

---

## 🎯 MVP（最小可行产品）建议

如果想快速验证，可以先实现 **MVP 版本**（3 个月）：

### MVP 核心功能
1. ✅ 基础 VPN 连接（单配置文件）
2. ✅ 云服务器管理（仅 Vultr）
3. ✅ 配置文件导入/导出
4. ✅ 连接状态显示
5. ✅ 基本设置

### MVP 排除功能
- ❌ 插件系统
- ❌ 定时任务
- ❌ 高级路由规则
- ❌ 规则集编辑器
- ❌ 命令行界面

---

## 📝 下一步行动

### 立即可做：
1. **决策确认** - 确认采用 Flutter 方案
2. **环境准备** - 安装 Flutter SDK、Android Studio、Xcode
3. **原型设计** - UI/UX 设计稿（Figma）
4. **API 设计** - 编写 API 接口文档

### 本周任务：
1. **创建 Flutter 项目** - `flutter create privatedeploy_mobile`
2. **配置构建环境** - Android/iOS 签名配置
3. **搭建 Go REST API** - 重构 bridge 代码

### 本月目标：
1. **完成 Phase 1** - 基础架构搭建完成
2. **演示 Demo** - 能够在手机上启动 VPN 连接

---

## 📚 参考资源

### Flutter VPN 开发
- [sing-box Android 示例](https://github.com/SagerNet/sing-box-for-android)
- [Flutter VPN Plugin](https://pub.dev/packages/flutter_vpn)
- [gomobile 文档](https://pkg.go.dev/golang.org/x/mobile/cmd/gomobile)

### API 设计
- [REST API 最佳实践](https://restfulapi.net/)
- [JWT 认证指南](https://jwt.io/introduction)

### UI/UX 参考
- [Clash for Android](https://github.com/Kr328/ClashForAndroid)
- [V2rayNG](https://github.com/2dust/v2rayNG)
- [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118)

---

## ✅ 成功标准

移动端开发完成的标准：

- ✅ 支持 Android 7.0+ 和 iOS 12.0+
- ✅ 功能与桌面版 100% 对等
- ✅ 启动时间 < 3 秒
- ✅ 内存占用 < 100MB（空闲状态）
- ✅ 电池消耗合理（24 小时后台 < 5%）
- ✅ 网络延迟增加 < 50ms
- ✅ 用户评分 > 4.0 星
- ✅ 崩溃率 < 0.5%

---

**文档版本：** v1.0
**创建日期：** 2025-11-04
**下次更新：** 启动开发后每周更新
