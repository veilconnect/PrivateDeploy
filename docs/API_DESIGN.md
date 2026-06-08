# PrivateDeploy REST API Design

**English** | [中文](API_DESIGN.zh-CN.md)

## 🌐 API Basics

**Base URL:** `https://api.privatedeploy.local:8443`
**Version:** v1
**Authentication:** No login, local / intranet control
**Data Format:** JSON

> Note: The current standalone API has removed `/api/v1/auth/*` and `/api/v1/vpn/*`.
> The legacy authentication / VPN control sections in this document represent historical design only and do not reflect the capabilities of the current build.

---

## 🔐 Authentication Endpoints

### Login
```http
POST /api/v1/auth/login
Content-Type: application/json

{
  "username": "admin",
  "password": "password"
}

Response:
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "expires_in": 86400
}
```

### Token Refresh
```http
POST /api/v1/auth/refresh
Authorization: Bearer <token>

Response:
{
  "token": "new_token...",
  "expires_in": 86400
}
```

---

## ☁️ Cloud Provider Management

### Get All Cloud Providers
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

### Set Active Cloud Provider
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

### Get Cloud Provider Configuration
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

### Save Cloud Provider Configuration
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

## 🖥️ Server Management

### Get Server List
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
      "ipv4": "203.0.113.1",
      "ipv6": "2400:8900::1",
      "createdAt": "2025-11-04T10:00:00Z",
      "tags": ["production"]
    }
  ]
}
```

### Create Server
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

### Delete Server
```http
DELETE /api/v1/cloud/instances/:id
Authorization: Bearer <token>

Response:
{
  "success": true,
  "message": "Instance deleted successfully"
}
```

### Get Region List
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

### Get Plan List
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

## 📋 Profile Management

### Get Profile List
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

### Get Profile Details
```http
GET /api/v1/profiles/:id
Authorization: Bearer <token>

Response:
{
  "profile": {
    "id": "profile-1",
    "name": "Default",
    "config": { /* sing-box config JSON */ }
  }
}
```

### Create/Update Profile
```http
POST /api/v1/profiles
Authorization: Bearer <token>
Content-Type: application/json

{
  "name": "Work Profile",
  "config": { /* sing-box config */ }
}

Response:
{
  "profile": {
    "id": "profile-2",
    "name": "Work Profile"
  }
}
```

### Delete Profile
```http
DELETE /api/v1/profiles/:id
Authorization: Bearer <token>

Response:
{
  "success": true
}
```

---

## 📡 Subscription Management

### Get Subscription List
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

### Add Subscription
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

### Update Subscription
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

## 🎯 Rule Set Management

### Get Rule Set List
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

### Get Rule Set Details
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

## 🔌 VPN Control

> Deprecated: The standalone API currently does not provide device-level VPN control endpoints.

### Start VPN
```http
POST /api/v1/vpn/start
Authorization: Bearer <token>
Content-Type: application/json

{
  "profileId": "profile-1"
}

Response:
{
  "success": true,
  "status": "connected"
}
```

### Stop VPN
```http
POST /api/v1/vpn/stop
Authorization: Bearer <token>

Response:
{
  "success": true,
  "status": "disconnected"
}
```

### Get VPN Status
```http
GET /api/v1/vpn/status
Authorization: Bearer <token>

Response:
{
  "status": "connected",
  "profileId": "profile-1",
  "uploadSpeed": 1024000,
  "downloadSpeed": 2048000,
  "totalUpload": 104857600,
  "totalDownload": 524288000,
  "connectedAt": "2025-11-04T10:00:00Z"
}
```

### Get Traffic Statistics
```http
GET /api/v1/vpn/stats
Authorization: Bearer <token>

Response:
{
  "upload": 104857600,
  "download": 524288000,
  "uploadSpeed": 1024000,
  "downloadSpeed": 2048000
}
```

---

## 📊 WebSocket Real-Time Notifications

### Connect
```
ws://api.privatedeploy.local:8443/ws
```

### Event Types

#### VPN Status Change
```json
{
  "type": "vpn_status",
  "data": {
    "status": "connected",
    "profileId": "profile-1"
  }
}
```

#### Traffic Update
```json
{
  "type": "traffic_update",
  "data": {
    "upload": 104857600,
    "download": 524288000,
    "uploadSpeed": 1024000,
    "downloadSpeed": 2048000
  }
}
```

#### Server Status Change
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

## 🛠️ System Management

### Get System Information
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

### Get Network Interfaces
```http
GET /api/v1/system/interfaces
Authorization: Bearer <token>

Response:
{
  "interfaces": ["eth0", "wlan0", "lo"]
}
```

### Exit Application
```http
POST /api/v1/system/exit
Authorization: Bearer <token>

Response:
{
  "success": true
}
```

---

## 📝 Error Response Format

```json
{
  "error": {
    "code": "INVALID_TOKEN",
    "message": "Invalid or expired token",
    "details": {}
  }
}
```

### Common Error Codes

| Code | HTTP Status | Description |
|------|-----------|------|
| `INVALID_TOKEN` | 401 | Token is invalid or expired |
| `UNAUTHORIZED` | 401 | Unauthorized |
| `NOT_FOUND` | 404 | Resource does not exist |
| `VALIDATION_ERROR` | 400 | Request parameter validation failed |
| `PROVIDER_ERROR` | 500 | Cloud provider API error |
| `VPN_ERROR` | 500 | VPN operation failed |

---

## 🚀 Implementation Priority

### Phase 1 (MVP)
- ✅ Authentication endpoints
- ✅ VPN control
- ✅ Profile management (basic)
- ✅ Cloud server management (list, create, delete)

### Phase 2
- ✅ Subscription management
- ✅ Rule set management
- ✅ WebSocket real-time notifications
- ✅ Traffic statistics

### Phase 3
- ✅ Full configuration editing
- ✅ Plugin system API
- ✅ Scheduled task API
- ✅ Advanced system management

---

**Document Version:** v1.0
**Created Date:** 2025-11-04
