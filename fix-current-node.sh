#!/bin/bash
# One-time fix script for current Vultr node: vultr-mgre203b
# IP: 64.176.41.153, Port: 37265

set -e

IP="64.176.41.153"
PORT="37265"

echo "==========================================="
echo "Fixing firewall for vultr-mgre203b"
echo "IP: $IP"
echo "Port: $PORT"
echo "==========================================="
echo ""

echo "Step 1: Testing current SSH connectivity..."
if timeout 5 bash -c "echo -n '' | nc -v $IP 22 2>&1" | grep -q "succeeded"; then
    echo "✓ SSH port is accessible"
else
    echo "✗ SSH port is not accessible. Cannot proceed."
    exit 1
fi

echo ""
echo "Step 2: Configuring firewall on the server..."
echo "Note: You may be prompted for the root password or need to have SSH keys configured."
echo ""

ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@"$IP" << 'EOF'
set -eux

echo "Installing UFW if needed..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y ufw

echo "Configuring firewall rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 37265/tcp
ufw allow 37265/udp
ufw --force enable

echo "Current firewall status:"
ufw status verbose

echo ""
echo "Verifying Docker container..."
docker ps | grep ss-server || echo "Warning: Shadowsocks container not running!"

echo ""
echo "Firewall configuration completed!"
EOF

echo ""
echo "Step 3: Testing Shadowsocks port connectivity..."
sleep 3

if timeout 10 nc -zv "$IP" "$PORT" 2>&1; then
    echo ""
    echo "==========================================="
    echo "✓ SUCCESS! Port $PORT is now accessible"
    echo "==========================================="
else
    echo ""
    echo "==========================================="
    echo "⚠ Port test failed. Possible reasons:"
    echo "  1. Firewall changes need more time to apply"
    echo "  2. Docker container is not running"
    echo "  3. Network issue"
    echo ""
    echo "Please wait 30 seconds and try testing again with:"
    echo "  nc -zv $IP $PORT"
    echo "==========================================="
fi
