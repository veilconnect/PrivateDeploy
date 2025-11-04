# PrivateDeploy REST API

PrivateDeploy 的 REST API 服务，为桌面端和移动端提供统一的后端接口。

## 📦 技术栈

- **Web 框架:** Gin
- **认证:** JWT (JSON Web Tokens)
- **数据库:** SQLite (GORM)
- **语言:** Go 1.22+

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
| `JWT_SECRET` | `privatedeploy-secret-change-me` | JWT 签名密钥 |
| `DB_PATH` | `data/privatedeploy.db` | SQLite 数据库路径 |
| `GIN_MODE` | `release` | Gin 模式 (debug/release) |

### 编译

```bash
go build -o privatedeploy-api
./privatedeploy-api
```

## 🔐 默认凭据

- **用户名:** `admin`
- **密码:** `admin`

⚠️ **请在首次登录后立即更改默认密码！**

## 📖 API 文档

详细的 API 文档请参阅 [API_DESIGN.md](../API_DESIGN.md)

### 健康检查

```bash
curl http://localhost:8443/api/v1/health
```

### 登录

```bash
curl -X POST http://localhost:8443/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}'
```

### 获取系统信息

```bash
curl http://localhost:8443/api/v1/system/info \
  -H "Authorization: Bearer YOUR_TOKEN"
```

## 🏗️ 项目结构

```
api/
├── main.go              # 主程序入口
├── config/              # 配置
│   └── config.go
├── handlers/            # HTTP 处理器
│   ├── auth.go
│   └── system.go
├── middleware/          # 中间件
│   └── auth.go
├── models/              # 数据模型
│   ├── auth.go
│   └── response.go
├── routes/              # 路由配置
│   └── routes.go
└── utils/               # 工具函数
    ├── jwt.go
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

### Phase 1 (当前)
- [x] 基础 HTTP 服务器
- [x] JWT 认证
- [x] 用户登录/Token 刷新
- [x] 系统信息接口
- [ ] 云服务商管理 API
- [ ] VPN 控制 API

### Phase 2
- [ ] WebSocket 实时通知
- [ ] 配置文件管理 API
- [ ] 订阅管理 API
- [ ] 规则集管理 API

### Phase 3
- [ ] 插件系统 API
- [ ] 定时任务 API
- [ ] 完整的单元测试
- [ ] API 文档自动生成 (Swagger)

## 🔒 安全

- ✅ JWT Token 认证
- ✅ 密码 bcrypt 加密
- ✅ CORS 支持
- ✅ 请求参数验证
- 🔄 HTTPS 支持 (待实现)
- 🔄 Rate Limiting (待实现)

## 📄 许可证

与 PrivateDeploy 主项目相同。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📞 联系

- 项目主页: https://github.com/veilconnect/PrivateDeploy
- 问题反馈: https://github.com/veilconnect/PrivateDeploy/issues
