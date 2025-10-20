#!/bin/bash
# Script to create Vultr firewall group and attach to instance via API
# This is an alternative solution when SSH access is not available

set -e

VULTR_API_KEY=REMOVED"
INSTANCE_ID="1b3bf592-336c-47d3-a4c1-031b23ab9d5e"
SS_PORT="37265"

echo "==========================================="
echo "Creating Vultr Firewall Group via API"
echo "==========================================="
echo ""

# Step 1: Create firewall group
echo "Step 1: Creating firewall group..."
FIREWALL_RESPONSE=$(curl -s -X POST "https://api.vultr.com/v2/firewalls" \
  -H "Authorization: Bearer $VULTR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "VeilDeploy Shadowsocks Firewall"
  }')

FIREWALL_ID=$(echo "$FIREWALL_RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['firewall_group']['id'])" 2>/dev/null)

if [ -z "$FIREWALL_ID" ]; then
    echo "Error: Failed to create firewall group"
    echo "Response: $FIREWALL_RESPONSE"
    exit 1
fi

echo "✓ Firewall group created: $FIREWALL_ID"
echo ""

# Step 2: Add SSH rule
echo "Step 2: Adding SSH rule (port 22)..."
curl -s -X POST "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/rules" \
  -H "Authorization: Bearer $VULTR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "ip_type": "v4",
    "protocol": "tcp",
    "subnet": "0.0.0.0",
    "subnet_size": 0,
    "port": "22",
    "notes": "SSH Access"
  }' > /dev/null

echo "✓ SSH rule added"

# Step 3: Add Shadowsocks TCP rule
echo "Step 3: Adding Shadowsocks TCP rule (port $SS_PORT)..."
curl -s -X POST "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/rules" \
  -H "Authorization: Bearer $VULTR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"ip_type\": \"v4\",
    \"protocol\": \"tcp\",
    \"subnet\": \"0.0.0.0\",
    \"subnet_size\": 0,
    \"port\": \"$SS_PORT\",
    \"notes\": \"Shadowsocks TCP\"
  }" > /dev/null

echo "✓ Shadowsocks TCP rule added"

# Step 4: Add Shadowsocks UDP rule
echo "Step 4: Adding Shadowsocks UDP rule (port $SS_PORT)..."
curl -s -X POST "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/rules" \
  -H "Authorization: Bearer $VULTR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"ip_type\": \"v4\",
    \"protocol\": \"udp\",
    \"subnet\": \"0.0.0.0\",
    \"subnet_size\": 0,
    \"port\": \"$SS_PORT\",
    \"notes\": \"Shadowsocks UDP\"
  }" > /dev/null

echo "✓ Shadowsocks UDP rule added"

# Step 5: Attach firewall to instance
echo ""
echo "Step 5: Attaching firewall to instance..."
ATTACH_RESPONSE=$(curl -s -X POST "https://api.vultr.com/v2/firewalls/$FIREWALL_ID/instances/$INSTANCE_ID" \
  -H "Authorization: Bearer $VULTR_API_KEY")

if echo "$ATTACH_RESPONSE" | grep -q "error"; then
    echo "⚠ Warning: Failed to attach firewall"
    echo "Response: $ATTACH_RESPONSE"
else
    echo "✓ Firewall attached to instance"
fi

echo ""
echo "==========================================="
echo "Firewall Configuration Summary"
echo "==========================================="
echo "Firewall Group ID: $FIREWALL_ID"
echo "Rules configured:"
echo "  - TCP/22  (SSH)"
echo "  - TCP/$SS_PORT (Shadowsocks)"
echo "  - UDP/$SS_PORT (Shadowsocks)"
echo ""
echo "Testing connectivity in 10 seconds..."
sleep 10

nc -zv 64.176.41.153 $SS_PORT 2>&1 && {
    echo ""
    echo "✓ SUCCESS! Port $SS_PORT is now accessible!"
} || {
    echo ""
    echo "⚠ Port test failed. The firewall may need more time to apply."
    echo "Please wait 30-60 seconds and test again with:"
    echo "  nc -zv 64.176.41.153 $SS_PORT"
}
