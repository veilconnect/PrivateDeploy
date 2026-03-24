# PrivateDeploy REST API

PrivateDeploy 的 REST API 服务，为桌面端和移动端提供统一的后端接口。

## 📦 技术栈

- **Web 框架:** Gin
- **认证:** 无登录，面向本地/内网控制
- **数据库:** SQLite (GORM)
- **语言:** Go 1.23+

## 🚀 快速开始

### 安装依赖

```bash
cd api
go mod download
```

### 运行服务器

```bash
go run main.go
```

服务器将在 `http://0.0.0.0:8443` 启动。

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `API_HOST` | `0.0.0.0` | 服务器监听地址 |
| `API_PORT` | `8443` | 服务器端口 |
| `API_WRITE_TIMEOUT` | `120s` | HTTP 响应写超时，支持 Go duration 格式 |
| `CORS_ALLOW_ORIGINS` | `http://localhost:5173,http://127.0.0.1:5173` | 允许的跨域来源（逗号分隔） |
| `DB_PATH` | `data/privatedeploy.db` | SQLite 数据库路径 |
| `GIN_MODE` | `release` | Gin 模式 (debug/release) |

### 编译

```bash
go build -o privatedeploy-api
./privatedeploy-api
```

## 🔓 认证模式

- 当前 API 运行在无登录模式下。
- 只要能够访问这台 API 主机，就可以直接调用 `/profiles`、`/subscriptions`、`/cloud`、`/system`。
- 推荐只在本机、局域网或受信任内网中使用，不要直接暴露到公网。

## 📖 API 文档

详细的 API 文档请参阅 [API_DESIGN.md](../API_DESIGN.md)

## ☁️ 云配置说明

- API 会返回 `hasApiKey`，用于告诉客户端当前激活 provider 是否已经在服务端安全存储了 API key。
- 实际 API key 不会在 `GET /api/v1/cloud/config` 响应中回传给客户端。
- 当前 standalone API 只对外暴露正式支持的 provider：`vultr`、`digitalocean`、`ssh`。
- 默认激活 provider 为 `vultr`。

### 健康检查

```bash
curl http://localhost:8443/api/v1/health
```

### 获取系统信息

```bash
curl http://localhost:8443/api/v1/system/info \
```

## 🏗️ 项目结构

```
api/
├── main.go              # 主程序入口
├── config/              # 配置
│   └── config.go
├── handlers/            # HTTP 处理器
│   ├── cloud.go
│   ├── profile.go
│   ├── subscription.go
│   ├── system.go
│   └── websocket.go
├── middleware/          # 中间件
│   └── cors.go
├── models/              # 数据模型
│   └── response.go
├── routes/              # 路由配置
│   └── routes.go
└── utils/               # 工具函数
    └── password.go
```

## 🧪 测试

### 运行测试

```bash
go test ./...
```

### 使用 Postman

导入 API 文档中的示例请求到 Postman 进行测试。

## 📝 开发计划

### 当前状态
- [x] 基础 HTTP 服务器
- [x] 系统信息接口
- [x] 云服务商管理 API
- [x] Profiles / Subscriptions CRUD API
- [x] WebSocket 连接入口
- [ ] Swagger / OpenAPI 自动文档

### 已知限制
- standalone API 不提供 `/vpn/*` 设备级控制接口。
- HTTPS 终止、反向代理和外网暴露策略应由部署环境负责。

### 后续方向
- [ ] 更完整的 WebSocket 推送事件
- [ ] 规则集 / 插件 / 定时任务 API
- [ ] 更高覆盖率的 handler / integration tests
- [ ] API 文档自动生成 (Swagger / OpenAPI)

## 🔒 安全

- ✅ CORS 支持
- ✅ 请求参数验证
- ✅ 本地 / 内网优先的无登录控制模式
- 🔄 HTTPS 支持 (待实现)
- 🔄 更细粒度的全局 Rate Limiting (待实现)

## 📄 许可证

与 PrivateDeploy 主项目相同。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📞 联系

- 项目主页: https://github.com/veilconnect/PrivateDeploy
- 问题反馈: https://github.com/veilconnect/PrivateDeploy/issues
