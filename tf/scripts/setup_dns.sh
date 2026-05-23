#!/bin/bash
# =============================================================================
# setup_dns.sh
#
# Configures systemd-resolved on the jumpbox to use EKS system nodes for DNS
# resolution of Kubernetes cluster.local domains via NodePort.
#
# Architecture:
#   Jumpbox -> System Node IPs:30053 -> kube-dns NodePort -> CoreDNS pods
#
# Benefits:
#   - No NLB cost (saves ~$16/month)
#   - Stable IPs (system nodes don't change)
#   - Direct access via VPC peering
#
# Usage:
#   sudo ./setup_dns.sh "<node_ips>"
#   Example: sudo ./setup_dns.sh "10.19.1.230 10.19.2.205"
#
# Or via cloud-init (user_data) where ${system_node_ips} is templated
# =============================================================================

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root (use sudo)"
   exit 1
fi

# Get system node IPs from argument or template variable
if [ $# -eq 1 ]; then
    SYSTEM_NODE_IPS="$1"
else
    # Template variable for cloud-init
    SYSTEM_NODE_IPS="${system_node_ips}"
fi

echo "=========================================="
echo "Configuring DNS resolution via NodePort"
echo "=========================================="

# Validate IPs are set and not empty
if [ -z "$SYSTEM_NODE_IPS" ] || [ "$SYSTEM_NODE_IPS" = "" ]; then
    echo "ERROR: System node IPs are not set or empty"
    echo ""
    echo "Usage: sudo $0 \"<ip1> <ip2>\""
    echo ""
    echo "To get the system node IPs from your cluster:"
    echo "  terraform output kube_dns_node_ips"
    exit 1
fi

echo "Using system node IPs: $SYSTEM_NODE_IPS"
echo "NodePort: 30053 (UDP/TCP)"
echo ""

# Create directory if it doesn't exist
mkdir -p /etc/systemd/resolved.conf.d

# Create resolved.conf configuration
# Note: systemd-resolved doesn't support custom ports in DNS= directive
# So we configure dnsmasq as a local forwarder instead
cat > /etc/dnsmasq.d/kube-dns.conf <<EOF
# Forward cluster.local queries to EKS system nodes on port 30053
server=/cluster.local/$SYSTEM_NODE_IPS#30053
server=/svc.cluster.local/$SYSTEM_NODE_IPS#30053
server=/confluent.svc.cluster.local/$SYSTEM_NODE_IPS#30053

# Cache DNS responses
cache-size=1000

# Listen only on localhost
listen-address=127.0.0.1
bind-interfaces
EOF

echo "✓ Created /etc/dnsmasq.d/kube-dns.conf"

# Install dnsmasq if not present
if ! command -v dnsmasq &> /dev/null; then
    echo "Installing dnsmasq..."
    yum install -y dnsmasq
fi

# Configure systemd-resolved to use local dnsmasq
cat > /etc/systemd/resolved.conf.d/kube-dns.conf <<EOF
[Resolve]
# Use local dnsmasq as DNS server
DNS=127.0.0.1

# Search domains for Kubernetes services
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local

# Enable DNS cache
Cache=yes
DNSStubListener=yes
EOF

echo "✓ Created /etc/systemd/resolved.conf.d/kube-dns.conf"

# Enable and start dnsmasq
systemctl enable dnsmasq
systemctl restart dnsmasq

# Restart systemd-resolved to apply configuration
echo "Restarting systemd-resolved..."
systemctl restart systemd-resolved

# Wait for DNS to be ready
sleep 5

# Verify DNS configuration
echo ""
echo "DNS Configuration Status:"
echo "----------------------------------------"
resolvectl status | grep -A 5 "Global" || resolvectl status | head -20

echo ""
echo "Testing DNS resolution:"
echo "----------------------------------------"

# Parse first IP from the list
FIRST_NODE_IP=$(echo "$SYSTEM_NODE_IPS" | awk '{print $1}')

# Test NodePort directly
if nc -zvu -w 2 "$FIRST_NODE_IP" 30053 2>&1 | grep -q "succeeded\|open\|Connected"; then
    echo "✓ NodePort 30053 is reachable on $FIRST_NODE_IP"
else
    echo "✗ NodePort 30053 is NOT reachable on $FIRST_NODE_IP"
    echo "  (System nodes may not be ready yet, wait 2-3 minutes)"
fi

# Test cluster DNS resolution
if dig kafka.confluent.svc.cluster.local +short +time=2 | grep -q "^10\."; then
    echo "✓ cluster.local DNS resolution working"
    echo "  Kafka IPs: $(dig kafka.confluent.svc.cluster.local +short +time=2 | head -3 | tr '\n' ' ')"
else
    echo "✗ cluster.local DNS resolution failed"
    echo "  (Kafka cluster may not be deployed yet)"
fi

# Test external DNS
if dig google.com +short +time=2 > /dev/null 2>&1; then
    echo "✓ External DNS resolution working"
else
    echo "✗ External DNS resolution failed"
fi

echo ""
echo "DNS setup complete!"
echo "=========================================="
echo ""
echo "System Node IPs: $SYSTEM_NODE_IPS"
echo "NodePort: 30053"
echo "Local DNS: dnsmasq on 127.0.0.1"
echo ""
echo "To test: dig kafka.confluent.svc.cluster.local +short"
