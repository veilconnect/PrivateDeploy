#!/bin/bash
# Script to add multi-protocol support to DigitalOcean provider
# This script adds the necessary functions and modifies CreateInstance

set -e

PROVIDER_FILE="bridge/cloud/providers/digitalocean/provider.go"
BACKUP_FILE="${PROVIDER_FILE}.backup-$(date +%Y%m%d_%H%M%S)"

echo "Creating backup: $BACKUP_FILE"
cp "$PROVIDER_FILE" "$BACKUP_FILE"

echo "Adding multi-protocol support to DigitalOcean provider..."

# Add necessary imports after the existing imports
sed -i '/^import (/a\        "crypto/rand"\n        mathrand "math/rand"\n        "os/exec"\n        "strings"' "$PROVIDER_FILE"

# Add helper functions before generateCloudInitScript
HELPER_FUNCTIONS=$(cat <<'EOF'

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

// shellEscape escapes a string for safe use in shell scripts
func shellEscape(s string) string {
        return strings.ReplaceAll(s, "'", "'\\''")
}
EOF
)

# Insert helper functions before generateRandomPassword
sed -i "/^func generateRandomPassword/i\\$HELPER_FUNCTIONS" "$PROVIDER_FILE"

echo "✅ Multi-protocol support functions added"
echo "⚠️  Manual steps required:"
echo "   1. Replace generateCloudInitScript function with multi-protocol version from Vultr"
echo "   2. Update CreateInstance function to generate credentials for all protocols"
echo "   3. Update CreateInstance to save all protocol credentials to InstanceRecord"
echo "   4. Update ListInstances to populate multi-protocol fields from records"
echo ""
echo "📄 See DIGITALOCEAN-MULTI-PROTOCOL-IMPLEMENTATION.md for detailed instructions"
