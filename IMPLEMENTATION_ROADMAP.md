# PrivateDeploy 移动端实施路线图

## 📅 执行时间：2025-11-04 开始

---

## ✅ Phase 1: 基础架构（Week 1-6）

### Week 1: 项目初始化 ⏰ 当前周

#### Day 1-2: 项目结构搭建
- [x] 创建项目目录结构
  ```
  PrivateDeploy/
  ├── api/                    # Go REST API 服务
  │   ├── main.go
  │   ├── handlers/
  │   ├── middleware/
  │   ├── models/
  │   └── routes/
  ├── mobile/                 # Flutter 移动端
  │   ├── android/
  │   ├── ios/
  │   ├── lib/
  │   └── pubspec.yaml
  ├── bridge/                 # 现有桌面端（保留）
  └── docs/                   # 文档
  ```
- [ ] 创建 API 项目基础文件
- [ ] 初始化 Git 分支策略

#### Day 3-4: Go REST API 框架
- [ ] 安装依赖（Gin、JWT、GORM）
- [ ] 实现基础 HTTP 服务器
- [ ] 实现 JWT 认证中间件
- [ ] 创建统一响应格式

#### Day 5-7: API 核心功能
- [ ] 实现认证接口（/api/v1/auth/*）
- [ ] 实现系统信息接口（/api/v1/system/*）
- [ ] 编写 API 单元测试
- [ ] 配置 CORS 和安全头

---

### Week 2: 云服务管理 API

#### Day 1-3: 云服务商接口
- [ ] 重构 bridge/cloud_bridge.go 为 HTTP 处理器
- [ ] 实现 /api/v1/cloud/providers
- [ ] 实现 /api/v1/cloud/config
- [ ] 实现 /api/v1/cloud/instances

#### Day 4-5: 区域和套餐接口
- [ ] 实现 /api/v1/cloud/regions
- [ ] 实现 /api/v1/cloud/plans
- [ ] 实现 /api/v1/cloud/availability

#### Day 6-7: 集成测试
- [ ] 测试 Vultr API 集成
- [ ] 测试 DigitalOcean API 集成
- [ ] 编写 Postman 测试集合

---

### Week 3: VPN 控制 API

#### Day 1-3: VPN 接口实现
- [ ] 实现 /api/v1/vpn/start
- [ ] 实现 /api/v1/vpn/stop
- [ ] 实现 /api/v1/vpn/status
- [ ] 实现 /api/v1/vpn/stats

#### Day 4-5: 配置文件管理
- [ ] 实现 /api/v1/profiles
- [ ] 实现配置 CRUD 操作
- [ ] 集成 sing-box 配置验证

#### Day 6-7: WebSocket 通知
- [ ] 实现 WebSocket 连接处理
- [ ] 实现实时状态推送
- [ ] 实现流量统计推送

---

### Week 4: Flutter 项目初始化

#### Day 1-2: 环境配置
- [ ] 安装 Flutter SDK
- [ ] 配置 Android Studio / Xcode
- [ ] 初始化 Flutter 项目
- [ ] 配置项目依赖（pubspec.yaml）

#### Day 3-4: 项目架构
- [ ] 创建目录结构（lib/）
  ```
  lib/
  ├── main.dart
  ├── app.dart
  ├── core/              # 核心功能
  │   ├── network/       # 网络请求
  │   ├── storage/       # 本地存储
  │   └── constants/     # 常量
  ├── features/          # 功能模块
  │   ├── auth/
  │   ├── home/
  │   ├── cloud/
  │   └── vpn/
  └── shared/            # 共享组件
      ├── widgets/
      └── utils/
  ```
- [ ] 配置状态管理（Provider）
- [ ] 配置路由（go_router）

#### Day 5-7: 基础功能实现
- [ ] 实现 API 客户端（Dio + Retrofit）
- [ ] 实现 JWT Token 管理
- [ ] 实现本地存储（Hive）
- [ ] 创建基础 UI 主题

---

### Week 5: gomobile 集成

#### Day 1-3: Go 移动库编译
- [ ] 安装 gomobile 工具
- [ ] 创建 Go 移动桥接代码
- [ ] 编译 Android AAR 库
- [ ] 编译 iOS Framework

#### Day 4-5: sing-box 集成
- [ ] 集成 sing-box 核心代码
- [ ] 实现 VPN 服务接口
- [ ] 测试 VPN 连接功能

#### Day 6-7: Platform Channel
- [ ] 实现 Android VpnService
- [ ] 实现 iOS Network Extension
- [ ] 测试原生层调用

---

### Week 6: MVP 核心功能

#### Day 1-2: 认证功能
- [ ] 实现登录页面
- [ ] 实现 Token 管理
- [ ] 实现自动登录

#### Day 3-4: 首页功能
- [ ] 实现连接状态显示
- [ ] 实现一键连接/断开
- [ ] 实现流量统计显示

#### Day 5-7: 集成测试
- [ ] 端到端测试（API + 移动端）
- [ ] 修复 Bug
- [ ] 性能优化

---

## 🎯 Phase 1 里程碑

完成 Week 1-6 后，应该达到：

- ✅ Go REST API 服务完整运行
- ✅ Flutter 项目能够启动
- ✅ 能够通过 API 登录认证
- ✅ 能够在手机上启动/停止 VPN
- ✅ 能够显示基本的连接状态

---

## 📊 当前进度

### 已完成（2025-11-04）
- ✅ 移动端开发计划文档
- ✅ API 接口设计文档
- ✅ 项目目录结构创建

### 进行中
- 🔄 Go REST API 项目初始化

### 待开始
- ⏳ Flutter 项目创建
- ⏳ gomobile 集成
- ⏳ sing-box 移动库编译

---

## 📝 每日更新日志

### 2025-11-04
- 创建完整的移动端开发计划
- 设计 REST API 接口规范
- 初始化项目目录结构
- 准备开始 API 服务器开发

---

## 🔗 相关文档

- [移动端开发计划](./MOBILE_DEVELOPMENT_PLAN.md)
- [API 接口设计](./API_DESIGN.md)
- [实施路线图](./IMPLEMENTATION_ROADMAP.md) （本文档）

---

**更新频率：** 每日更新进度
**负责人：** 开发团队
**开始日期：** 2025-11-04
