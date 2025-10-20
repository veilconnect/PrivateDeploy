#!/bin/bash
# Script to fix firewall rules on existing Vultr node
# Usage: ./fix-firewall.sh <IP> <PORT>

set -e

if [ $# -ne 2 ]; then
    echo "Usage: $0 <IP_ADDRESS> <SHADOWSOCKS_PORT>"
    echo "Example: $0 64.176.41.153 37265"
    exit 1
fi

IP="$1"
PORT="$2"

echo "Fixing firewall rules on $IP for port $PORT..."

# SSH command to configure firewall
ssh -o StrictHostKeyChecking=no root@"$IP" << EOF
set -eux

# Install ufw if not already installed
if ! command -v ufw &> /dev/null; then
    apt-get update
    apt-get install -y ufw
fi

# Configure firewall
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow ${PORT}/tcp
ufw allow ${PORT}/udp
ufw --force enable

# Verify firewall status
echo "Firewall status:"
ufw status verbose

echo "Firewall configuration completed successfully!"
EOF

echo ""
echo "Firewall fix completed! Testing connection..."
sleep 2
nc -zv -w 5 "$IP" "$PORT" 2>&1 || echo "Note: Port may take a few seconds to become accessible"
