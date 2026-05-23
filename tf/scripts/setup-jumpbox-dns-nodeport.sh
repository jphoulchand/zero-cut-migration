#!/bin/bash
# =============================================================================
# Setup Jumpbox DNS via NodePort
# =============================================================================
# Quick script to configure DNS on the jumpbox to access Kubernetes cluster.local
# domains via system node NodePort (instead of NLB).
#
# Run this ON THE JUMPBOX as root:
#   sudo ./setup-jumpbox-dns-nodeport.sh
# =============================================================================

set -euo pipefail

# System node IPs (from EKS cluster)
SYSTEM_NODE_IPS="10.19.1.230 10.19.2.205"
NODEPORT="30053"

echo "=========================================="
echo "Configuring DNS via NodePort"
echo "=========================================="
echo "System Nodes: $SYSTEM_NODE_IPS"
echo "NodePort: $NODEPORT"
echo ""

# Install dnsmasq if not present
if ! command -v dnsmasq &> /dev/null; then
    echo "Installing dnsmasq..."
    yum install -y dnsmasq
fi

# Configure dnsmasq to forward cluster.local queries to system nodes on port 30053
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/kube-dns.conf <<EOF
# Forward cluster.local queries to EKS system nodes on port 30053
EOF

# Add each system node IP as a DNS server for cluster domains
for IP in $SYSTEM_NODE_IPS; do
    cat >> /etc/dnsmasq.d/kube-dns.conf <<EOF
server=/cluster.local/${IP}#${NODEPORT}
server=/svc.cluster.local/${IP}#${NODEPORT}
server=/confluent.svc.cluster.local/${IP}#${NODEPORT}
EOF
done

cat >> /etc/dnsmasq.d/kube-dns.conf <<EOF

# Cache DNS responses
cache-size=1000

# Listen only on localhost
listen-address=127.0.0.1
bind-interfaces
EOF

echo "✓ Created /etc/dnsmasq.d/kube-dns.conf"

# Configure systemd-resolved to use local dnsmasq
mkdir -p /etc/systemd/resolved.conf.d
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

# Enable and restart services
systemctl enable dnsmasq
systemctl restart dnsmasq
systemctl restart systemd-resolved

echo ""
echo "Waiting for DNS to initialize..."
sleep 5

# Test DNS resolution
echo ""
echo "Testing DNS resolution:"
echo "----------------------------------------"

# Test NodePort connectivity
FIRST_IP=$(echo "$SYSTEM_NODE_IPS" | awk '{print $1}')
if nc -zvu -w 2 "$FIRST_IP" "$NODEPORT" 2>&1 | grep -q "succeeded\|open\|Connected"; then
    echo "✓ NodePort $NODEPORT is reachable on $FIRST_IP"
else
    echo "✗ Warning: NodePort $NODEPORT not reachable on $FIRST_IP"
fi

# Test cluster DNS
if dig kafka.confluent.svc.cluster.local +short +time=2 2>/dev/null | grep -q "^10\."; then
    echo "✓ Cluster DNS resolution working!"
    echo ""
    echo "Kafka service IPs:"
    dig kafka.confluent.svc.cluster.local +short +time=2 | head -5
else
    echo "⚠ Cluster DNS not resolving yet (Kafka may not be deployed)"
    echo ""
    echo "Testing kube-dns directly:"
    dig @${FIRST_IP} -p ${NODEPORT} kubernetes.default.svc.cluster.local +short +time=2
fi

# Test external DNS
if dig google.com +short +time=2 > /dev/null 2>&1; then
    echo ""
    echo "✓ External DNS resolution working"
fi

echo ""
echo "=========================================="
echo "DNS Configuration Complete!"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  - System Nodes: $SYSTEM_NODE_IPS"
echo "  - NodePort: $NODEPORT"
echo "  - Local DNS: dnsmasq on 127.0.0.1"
echo ""
echo "Test commands:"
echo "  dig kafka.confluent.svc.cluster.local +short"
echo "  dig kraftcontroller.confluent.svc.cluster.local +short"
echo "  dig kafka-0.kafka.confluent.svc.cluster.local +short"
echo ""
