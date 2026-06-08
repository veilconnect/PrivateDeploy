# PrivateDeploy REST API

**English** | [中文](README.zh-CN.md)

The REST API service for PrivateDeploy, providing a unified backend interface for desktop and mobile clients.

## 📦 Tech Stack

- **Web framework:** Gin
- **Authentication:** Local-only access by default, with optional token authentication
- **Database:** SQLite (GORM)
- **Language:** Go 1.23+

## 🚀 Quick Start

### Install dependencies

```bash
cd api
go mod download
```

### Run the server

```bash
go run main.go
```

By default the server starts at `http://127.0.0.1:8443`.

### Environment variables

| Variable | Default | Description |
|------|--------|------|
| `API_HOST` | `127.0.0.1` | Server listen address |
| `API_PORT` | `8443` | Server port |
| `API_ALLOW_REMOTE` | `false` | Whether to allow non-loopback client access |
| `API_AUTH_TOKEN` | `` | Optional shared token; once set, access requires `Authorization: Bearer <token>` or `X-PrivateDeploy-Token` |
| `API_AUTH_TOKEN_FILE` | `` | Read the token from a file, suitable for container/secret mounts |
| `API_WRITE_TIMEOUT` | `120s` | HTTP response write timeout, supports Go duration format |
| `CORS_ALLOW_ORIGINS` | `http://localhost:5173,http://127.0.0.1:5173` | Allowed cross-origin origins (comma-separated) |
| `DB_PATH` | `data/privatedeploy.db` | SQLite database path |
| `GIN_MODE` | `release` | Gin mode (debug/release) |

### Build

```bash
go build -o privatedeploy-api
./privatedeploy-api
```

## 🔓 Access Control

- By default only local requests from `127.0.0.1` / `::1` are accepted.
- For LAN or remote access, explicitly set `API_ALLOW_REMOTE=true`.
- For shared access, it is recommended to also set `API_AUTH_TOKEN` or `API_AUTH_TOKEN_FILE`.
- Even with remote access enabled, exposing it directly to the public internet is not recommended; place it behind a reverse proxy, VPN, or trusted network.

## 📖 API Documentation

For detailed API documentation, see [API_DESIGN.md](../docs/API_DESIGN.md)

## ☁️ Cloud Configuration Notes

- The API returns `hasApiKey` to tell the client whether the currently active provider already has an API key securely stored on the server side.
- The actual API key is not returned to the client in the `GET /api/v1/cloud/config` response.
- The current standalone API only exposes officially supported providers: `vultr`, `digitalocean`, `ssh`.
- The default active provider is `vultr`.

### Health check

```bash
curl http://localhost:8443/api/v1/health
```

### Get system information

```bash
curl http://localhost:8443/api/v1/system/info \
```

## 🏗️ Project Structure

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

## 🧪 Testing

### Run tests

```bash
go test ./...
```

### Using Postman

Import the example requests from the API documentation into Postman for testing.

## 📝 Development Plan

### Current Status
- [x] Basic HTTP server
- [x] System information endpoint
- [x] Cloud provider management API
- [x] Profiles / Subscriptions CRUD API
- [x] WebSocket connection entry point
- [ ] Swagger / OpenAPI automatic documentation

### Known Limitations
- The standalone API does not provide device-level `/vpn/*` control endpoints.
- HTTPS termination, reverse proxy, and public-exposure policies should be handled by the deployment environment.

### Future Directions
- [ ] More complete WebSocket push events
- [ ] Rule set / plugin / scheduled task API
- [ ] Higher-coverage handler / integration tests
- [ ] Automatic API documentation generation (Swagger / OpenAPI)

## 🔒 Security

- ✅ CORS support
- ✅ Request parameter validation
- ✅ Local-only access by default
- ✅ Optional token authentication
- 🔄 HTTPS support (to be implemented)
- 🔄 More fine-grained global Rate Limiting (to be implemented)

## 📄 License

Same as the main PrivateDeploy project.

## 🤝 Contributing

Issues and Pull Requests are welcome!

## 📞 Contact

- Project homepage: https://github.com/veilconnect/PrivateDeploy
- Issue reporting: https://github.com/veilconnect/PrivateDeploy/issues
