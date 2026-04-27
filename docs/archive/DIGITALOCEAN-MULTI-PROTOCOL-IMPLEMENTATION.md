# DigitalOcean 多协议支持实现说明 (PrivateDeploy)

## 概述
为 DigitalOcean provider 添加完整的多协议支持（Shadow socks + Hysteria2 + VLESS-Reality + Trojan），参考 Vultr 的成功实现。

## 修改文件
`bridge/cloud/providers/digitalocean/provider.go`

## 需要添加的辅助函数

### 1. 添加 UUID 生成函数（在 generateRandomPassword 后面）

```go
// generateUUID generates a random UUID v4
func generateUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// Fallback to math/rand if crypto/rand fails
		for i := range b {
			b[i] = byte(mathrand.Intn(256))
		}
	}
	// Set version (4) and variant bits
	b[6] = (b[6] & 0x0f) | 0x40 // Version 4
	b[8] = (b[8] & 0x3f) | 0x80 // Variant is 10
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
```

### 2. 添加 Reality 密钥生成函数

需要导入 `os/exec` 和 `strings` 包，然后添加：

```go
// generateRealityKeyPair generates a Reality key pair using sing-box command
func generateRealityKeyPair() (privateKey, publicKey string, err error) {
	// Try to find sing-box in common locations
	singboxPaths := []string{
		"/usr/local/bin/sing-box",
		"/usr/bin/sing-box",
		"sing-box", // PATH lookup
	}

	var cmd *exec.Cmd
	for _, path := range singboxPaths {
		cmd = exec.Command(path, "generate", "reality-keypair")
		output, execErr := cmd.CombinedOutput()
		if execErr == nil {
			lines := strings.Split(strings.TrimSpace(string(output)), "\n")
			for _, line := range lines {
				if strings.HasPrefix(line, "PrivateKey: ") {
					privateKey = strings.TrimPrefix(line, "PrivateKey: ")
				} else if strings.HasPrefix(line, "PublicKey: ") {
					publicKey = strings.TrimPrefix(line, "PublicKey: ")
				}
			}
			if privateKey != "" && publicKey != "" {
				return privateKey, publicKey, nil
			}
		}
	}
	return "", "", fmt.Errorf("failed to generate Reality keypair: sing-box not found or execution failed")
}
```

### 3. 添加 shell 转义函数

```go
// shellEscape escapes a string for safe use in shell scripts
func shellEscape(s string) string {
	return strings.ReplaceAll(s, "'", "'\\''")
}
```

## CreateInstance 函数修改

将 CreateInstance 函数中的密码和部署脚本生成部分替换为：

```go
func (p *Provider) CreateInstance(ctx context.Context, opts *cloud.CreateInstanceOptions) (*cloud.Instance, error) {
	if opts == nil {
		return nil, fmt.Errorf("create options cannot be nil")
	}

	// Generate credentials for all protocols
	ssPort := 23650
	ssPassword := generateRandomPassword(16)
	hysteriaPort := 23651
	hysteriaPassword := generateRandomPassword(22)
	vlessPort := 23652
	vlessUUID := generateUUID()
	trojanPort := 23653
	trojanPassword := generateRandomPassword(22)

	// Generate Reality keypair
	realityPrivateKey, realityPublicKey, err := generateRealityKeyPair()
	if err != nil {
		// Log warning but continue with empty keys
		fmt.Printf("Warning: failed to generate Reality keypair: %v\n", err)
		realityPrivateKey = ""
		realityPublicKey = ""
	}
	realityShortID := fmt.Sprintf("%016x", mathrand.Int63())

	// Generate cloud-init user data script with all protocols
	userData := generateMultiProtocolScript(
		ssPort, ssPassword,
		hysteriaPort, hysteriaPassword,
		vlessPort, vlessUUID,
		trojanPort, trojanPassword,
		realityPrivateKey, realityPublicKey, realityShortID,
	)

	// ... rest of the CreateInstance function remains the same until saving node records...

	// Save multi-protocol information to node records
	record := cloud.InstanceRecord{
		Plan:             opts.Plan,
		CreatedAt:        result.Droplet.CreatedAt.Format(time.RFC3339),
		SSPort:           ssPort,
		SSPassword:       ssPassword,
		HysteriaPort:     hysteriaPort,
		HysteriaPassword: hysteriaPassword,
		VLESSPort:        vlessPort,
		VLESSUUID:        vlessUUID,
		VLESSPublicKey:   realityPublicKey,
		VLESSShortID:     realityShortID,
		TrojanPort:       trojanPort,
		TrojanPassword:   trojanPassword,
	}

	// ... rest remains the same...

	return instance, nil
}
```

## generateCloudInitScript 函数替换

完全替换 `generateCloudInitScript` 函数为 `generateMultiProtocolScript`，使用与 Vultr 相同的完整多协议部署脚本。

参考文件: `bridge/vultr.go` 行 909-1188

关键修改点：
1. 函数签名改为接受所有协议的参数
2. 脚本内容与 Vultr 完全一致，包括：
   - Docker 和 UFW 安装
   - 证书生成
   - 防火墙配置（4个端口）
   - Shadowsocks 容器部署
   - Hysteria2 容器部署
   - VLESS-Reality systemd 服务部署
   - Trojan systemd 服务部署
   - 验证和摘要输出

## ListInstances 函数修改

在 ListInstances 中填充多协议字段：

```go
// After getting instance from API and node records
if record, exists := records[instanceID]; exists {
	instance.SSPort = record.SSPort
	instance.SSPassword = record.SSPassword
	instance.HysteriaPort = record.HysteriaPort
	instance.HysteriaPassword = record.HysteriaPassword
	instance.VLESSPort = record.VLESSPort
	instance.VLESSUUID = record.VLESSUUID
	instance.VLESSPublicKey = record.VLESSPublicKey
	instance.VLESSShortID = record.VLESSShortID
	instance.TrojanPort = record.TrojanPort
	instance.TrojanPassword = record.TrojanPassword
}
```

## 导入包更新

需要在文件顶部添加：

```go
import (
	// ... existing imports ...
	"crypto/rand"
	mathrand "math/rand"
	"os/exec"
	"strings"
)
```

## 测试步骤

1. 编译项目
2. 使用 DigitalOcean API Key 创建新节点
3. SSH 登录节点检查 `/var/log/veildeploy-init.log`
4. 验证所有4个端口正在监听
5. 测试每个协议的连接性

## 预期结果

部署完成后，DigitalOcean 节点应该具有与 Vultr 相同的多协议配置：
- Shadowsocks: Port 23650 (TCP/UDP)
- Hysteria2: Port 23651 (UDP)
- VLESS-Reality: Port 23652 (TCP)
- Trojan: Port 23653 (TCP)
