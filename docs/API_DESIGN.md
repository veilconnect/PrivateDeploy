# PrivateDeploy REST API 设计

## 🌐 API 基础信息

**Base URL:** `https://api.privatedeploy.local:8443`
**版本:** v1
**认证方式:** 默认绑定本地回环、无需登录；当 API 监听非回环地址时必须设置
`API_AUTH_TOKEN`（请求头 `Authorization: Bearer <token>`，见 `api/config`）。
**数据格式:** JSON

> **权威来源：** 实际可用端点以 Gin 路由(`api/routes/routes.go`)和运行时生成的
> `GET /api/v1/openapi.yaml` 为准；本文档是设计说明，可能滞后。
> standalone API **已移除** `/api/v1/auth/*`(JWT 登录/刷新)和 `/api/v1/vpn/*`,
> 故本文不再保留这些章节。

---

## ☁️ 云服务商管理

### 获取所有云服务商
```http
GET /api/v1/cloud/providers
Authorization: Bearer <token>

Response:
{
  "providers": [
    {
      "name": "vultr",
      "displayName": "Vultr",
      "enabled": true
    },
    {
      "name": "digitalocean",
      "displayName": "DigitalOcean",
      "enabled": true
    }
  ]
}
```

### 设置活动云服务商
```http
POST /api/v1/cloud/provider/active
Authorization: Bearer <token>
Content-Type: application/json

{
  "provider": "vultr"
}

Response:
{
  "success": true,
  "provider": "vultr"
}
```

### 获取云服务商配置
```http
GET /api/v1/cloud/config?provider=vultr
Authorization: Bearer <token>

Response:
{
  "provider": "vultr",
  "apiKey": "***",
  "defaultRegion": "nrt",
  "defaultPlan": "vc2-1c-1gb"
}
```

### 保存云服务商配置
```http
POST /api/v1/cloud/config
Authorization: Bearer <token>
Content-Type: application/json

{
  "provider": "vultr",
  "apiKey": "YOUR_API_KEY",
  "defaultRegion": "nrt",
  "defaultPlan": "vc2-1c-1gb"
}

Response:
{
  "success": true
}
```

---

## 🖥️ 服务器管理

### 获取服务器列表
```http
GET /api/v1/cloud/instances?provider=vultr
Authorization: Bearer <token>

Response:
{
  "instances": [
    {
      "id": "vultr-abc123",
      "label": "Tokyo-Node-1",
      "status": "active",
      "region": "nrt",
      "plan": "vc2-1c-1gb",
      "ipv4": "139.162.1.1",
      "ipv6": "2001:db8::1",
      "createdAt": "2025-11-04T10:00:00Z",
      "tags": ["production"]
    }
  ]
}
```

### 创建服务器
```http
POST /api/v1/cloud/instances
Authorization: Bearer <token>
Content-Type: application/json

{
  "provider": "vultr",
  "region": "nrt",
  "plan": "vc2-1c-1gb",
  "label": "Tokyo-Node-2",
  "osId": "ubuntu-22.04",
  "enableIpv6": true
}

Response:
{
  "instance": {
    "id": "vultr-def456",
    "label": "Tokyo-Node-2",
    "status": "pending",
    "region": "nrt",
    "plan": "vc2-1c-1gb",
    "createdAt": "2025-11-04T11:00:00Z"
  }
}
```

### 删除服务器
```http
DELETE /api/v1/cloud/instances/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "message": "Instance deleted successfully"
}
```

### 获取区域列表
```http
GET /api/v1/cloud/regions?provider=vultr
Authorization: Bearer <token>

Response:
{
  "regions": [
    {
      "id": "nrt",
      "name": "Tokyo",
      "country": "JP",
      "available": true
    }
  ]
}
```

### 获取套餐列表
```http
GET /api/v1/cloud/plans?provider=vultr&region=nrt
Authorization: Bearer <token>

Response:
{
  "plans": [
    {
      "id": "vc2-1c-1gb",
      "name": "1 vCPU / 1 GB RAM",
      "vcpu": 1,
      "ram": 1024,
      "disk": 25,
      "bandwidth": 1000,
      "price": 6.0
    }
  ]
}
```

---

## 📋 配置文件管理

### 获取配置文件列表
```http
GET /api/v1/profiles
Authorization: Bearer <token>

Response:
{
  "profiles": [
    {
      "id": "profile-1",
      "name": "Default",
      "type": "local",
      "active": true,
      "createdAt": "2025-11-01T00:00:00Z",
      "updatedAt": "2025-11-04T10:00:00Z"
    }
  ]
}
```

### 获取配置文件详情
```http
GET /api/v1/profiles/:id
Authorization: Bearer <token>

Response:
{
  "profile": {
    "id": "profile-1",
    "name": "Default",
    "config": { /* sing-box 配置 JSON */ }
  }
}
```

### 创建/更新配置文件
```http
POST /api/v1/profiles
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "Work Profile",
  "config": { /* sing-box 配置 */ }
}

Response:
{
  "profile": {
    "id": "profile-2",
    "name": "Work Profile"
  }
}
```

### 删除配置文件
```http
DELETE /api/v1/profiles/:id
Authorization: Bearer <token>

Response:
{
  "success": true
}
```

---

## 📡 订阅管理

### 获取订阅列表
```http
GET /api/v1/subscriptions
Authorization: Bearer <token>

Response:
{
  "subscriptions": [
    {
      "id": "sub-1",
      "name": "机场A",
      "url": "https://example.com/sub",
      "updatedAt": "2025-11-04T10:00:00Z",
      "nodeCount": 50
    }
  ]
}
```

### 添加订阅
```http
POST /api/v1/subscriptions
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "机场B",
  "url": "https://example.com/sub2"
}

Response:
{
  "subscription": {
    "id": "sub-2",
    "name": "机场B",
    "nodeCount": 30
  }
}
```

### 更新订阅
```http
PUT /api/v1/subscriptions/:id/refresh
Authorization: Bearer <token>

Response:
{
  "success": true,
  "nodeCount": 32,
  "updatedAt": "2025-11-04T11:00:00Z"
}
```

---

## 🎯 规则集管理

### 获取规则集列表
```http
GET /api/v1/rulesets
Authorization: Bearer <token>

Response:
{
  "rulesets": [
    {
      "id": "ruleset-1",
      "name": "广告屏蔽",
      "type": "domain",
      "ruleCount": 1000
    }
  ]
}
```

### 获取规则集详情
```http
GET /api/v1/rulesets/:id
Authorization: Bearer <token>

Response:
{
  "ruleset": {
    "id": "ruleset-1",
    "name": "广告屏蔽",
    "rules": ["domain:ads.example.com", ...]
  }
}
```

---

## 📊 WebSocket 实时通知

### 连接
```
ws://api.privatedeploy.local:8443/ws
```

### 事件类型

#### 服务器状态变化
```json
{
  "type": "instance_status",
  "data": {
    "id": "vultr-abc123",
    "status": "active"
  }
}
```

---

## 🛠️ 系统管理

### 获取系统信息
```http
GET /api/v1/system/info
Authorization: Bearer <token>

Response:
{
  "appName": "PrivateDeploy",
  "version": "1.10.1",
  "os": "linux",
  "arch": "amd64",
  "basePath": "/opt/privatedeploy"
}
```

### 获取网络接口
```http
GET /api/v1/system/interfaces
Authorization: Bearer <token>

Response:
{
  "interfaces": ["eth0", "wlan0", "lo"]
}
```

### 退出应用
```http
POST /api/v1/system/exit
Authorization: Bearer <token>

Response:
{
  "success": true
}
```

---

## 📝 错误响应格式

```json
{
  "error": {
    "code": "INVALID_TOKEN",
    "message": "Invalid or expired token",
    "details": {}
  }
}
```

### 常见错误代码

| 代码 | HTTP 状态 | 说明 |
|------|-----------|------|
| `INVALID_TOKEN` | 401 | Token 无效或过期 |
| `UNAUTHORIZED` | 401 | 未授权 |
| `NOT_FOUND` | 404 | 资源不存在 |
| `VALIDATION_ERROR` | 400 | 请求参数验证失败 |
| `PROVIDER_ERROR` | 500 | 云服务商 API 错误 |
| `VPN_ERROR` | 500 | VPN 操作失败 |

---

## 🚀 实现优先级

### Phase 1（MVP）
- ✅ 认证接口
- ✅ VPN 控制
- ✅ 配置文件管理（基础）
- ✅ 云服务器管理（列表、创建、删除）

### Phase 2
- ✅ 订阅管理
- ✅ 规则集管理
- ✅ WebSocket 实时通知
- ✅ 流量统计

### Phase 3
- ✅ 完整的配置编辑
- ✅ 插件系统 API
- ✅ 定时任务 API
- ✅ 高级系统管理

---

**文档版本：** v1.0
**创建日期：** 2025-11-04
