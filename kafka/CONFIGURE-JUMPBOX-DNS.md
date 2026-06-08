# Configure Jumpbox DNS for Kubernetes Cluster Access

## NodePort DNS Configuration

CoreDNS is exposed via NodePort on the system nodes (no NLB cost):

```
System Node IPs: 10.19.1.230 10.19.2.205
NodePort: 30053 (UDP/TCP)
Architecture: Jumpbox -> System Nodes:30053 -> CoreDNS pods
Cost: FREE (was $16/month with NLB)
```

## Quick Setup (Recommended)

### Option 1: Automated Script

```bash
# On your local machine
scp -i ~/.ssh/your-key.pem tf/scripts/setup-jumpbox-dns-nodeport.sh ec2-user@<jumpbox-ip>:~/

# SSH to jumpbox
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>

# Run setup script
sudo bash setup-jumpbox-dns-nodeport.sh
```

This installs dnsmasq and configures it to forward cluster.local queries to the system nodes on port 30053.

### Option 2: Manual Configuration

```bash
# SSH to jumpbox
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>

# Install dnsmasq
sudo yum install -y dnsmasq

# Configure dnsmasq to forward cluster DNS to system nodes on port 30053
sudo tee /etc/dnsmasq.d/kube-dns.conf > /dev/null <<'EOF'
# Forward cluster.local queries to EKS system nodes on port 30053
server=/cluster.local/10.19.1.230#30053
server=/svc.cluster.local/10.19.1.230#30053
server=/confluent.svc.cluster.local/10.19.1.230#30053
server=/cluster.local/10.19.2.205#30053
server=/svc.cluster.local/10.19.2.205#30053
server=/confluent.svc.cluster.local/10.19.2.205#30053

# Cache DNS responses
cache-size=1000

# Listen only on localhost
listen-address=127.0.0.1
bind-interfaces
EOF

# Configure systemd-resolved to use dnsmasq
sudo tee /etc/systemd/resolved.conf.d/kube-dns.conf > /dev/null <<'EOF'
[Resolve]
DNS=127.0.0.1
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
Cache=yes
DNSStubListener=yes
EOF

# Enable and start services
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq
sudo systemctl restart systemd-resolved

# Wait for DNS to initialize
sleep 5
```

## Why dnsmasq?

systemd-resolved's DNS= directive doesn't support custom ports. Since our CoreDNS is exposed on NodePort 30053 (not standard port 53), we use dnsmasq as a local forwarder that:
1. Accepts queries on standard port 53
2. Forwards cluster.local queries to system nodes on port 30053
3. Provides caching for better performance

## Test DNS Resolution

```bash
# Test CoreDNS is reachable
dig @52.214.59.204 google.com +short

# Test Kafka service resolution
dig kafka.confluent.svc.cluster.local +short

# Test specific broker resolution
dig kafka-0.kafka.confluent.svc.cluster.local +short

# Test with full query
dig kafka.confluent.svc.cluster.local

# List all Kafka broker IPs
for i in {0..11}; do
  echo "kafka-$i: $(dig kafka-$i.kafka.confluent.svc.cluster.local +short)"
done
```

## Expected Results

### Kafka Service Resolution

```bash
$ dig kafka.confluent.svc.cluster.local +short
10.19.1.104
10.19.2.135
10.19.3.83
# (up to 12 IPs for 12 brokers)
```

### Individual Broker Resolution

```bash
$ dig kafka-0.kafka.confluent.svc.cluster.local +short
10.19.1.104
```

### KRaft Controller Resolution

```bash
$ dig kraftcontroller.confluent.svc.cluster.local +short
10.19.2.50
10.19.1.45
# (5 IPs for 5 controllers)
```

## Troubleshooting

### DNS Not Resolving

```bash
# Check if NLB is reachable
ping 52.214.59.204

# Test NLB DNS directly
dig @52.214.59.204 kafka.confluent.svc.cluster.local +short

# Check systemd-resolved status
systemctl status systemd-resolved

# View systemd-resolved logs
journalctl -u systemd-resolved -n 50

# Check current DNS servers
resolvectl status | grep "DNS Servers"
```

### Wrong IP Addresses

If NLB IPs change (unlikely but possible), get new IPs:

```bash
# From your local machine (not jumpbox)
nslookup a5c08042efb3c426cab26b80950cdd9c-5cc13eb909a94678.elb.eu-west-1.amazonaws.com

# Or using kubectl
kubectl get svc kube-dns-external -n kube-system \
  -o jsonpath='{.status.loadBalancer.ingress[*].hostname}{"\n"}'
```

### NLB Not Responding

```bash
# Check NLB health from local machine
kubectl get svc kube-dns-external -n kube-system

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test NLB endpoint
nc -zv 52.214.59.204 53
```

## Verify Kafka Connectivity

Once DNS is working, test Kafka connectivity:

```bash
# Install Kafka client tools (if not already installed)
cd /opt/binaries/cp/bin

# Test broker API versions
./kafka-broker-api-versions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071

# List topics (should show internal topics)
./kafka-topics \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --list
```

## Automated Setup Script

Save this as `setup-jumpbox-dns.sh`:

```bash
#!/bin/bash
set -e

echo "Configuring DNS for Kubernetes cluster access..."

# NLB IPs
NLB_IPS="52.214.59.204 52.209.78.3 52.214.106.159"

# Create systemd-resolved configuration
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/kube-dns.conf > /dev/null <<EOF
[Resolve]
DNS=$NLB_IPS
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
Cache=yes
DNSStubListener=yes
EOF

# Restart systemd-resolved
sudo systemctl restart systemd-resolved
sleep 3

# Test DNS
echo ""
echo "Testing DNS resolution..."
if dig kafka.confluent.svc.cluster.local +short | grep -q "^10\."; then
    echo "✓ DNS resolution working!"
    echo ""
    echo "Kafka service IPs:"
    dig kafka.confluent.svc.cluster.local +short
else
    echo "✗ DNS resolution failed"
    echo "Check NLB status and CoreDNS pods"
    exit 1
fi
```

Run it:

```bash
chmod +x setup-jumpbox-dns.sh
./setup-jumpbox-dns.sh
```

## Persistent Configuration

The systemd-resolved method persists across reboots. To verify:

```bash
# Reboot jumpbox
sudo reboot

# After reboot, SSH back in and test
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>
dig kafka.confluent.svc.cluster.local +short
```

## Notes

- **NLB Cost**: ~$16/month for the DNS load balancer
- **Latency**: Minor (<5ms) due to NLB hop
- **HA**: NLB is multi-AZ, automatically routes to healthy CoreDNS pods
- **Updates**: NLB IPs rarely change, but if they do, repeat configuration

## Quick Reference

```bash
# Current Configuration
NLB Hostname: a5c08042efb3c426cab26b80950cdd9c-5cc13eb909a94678.elb.eu-west-1.amazonaws.com
NLB IPs: 52.214.59.204, 52.209.78.3, 52.214.106.159
Jumpbox IP: <jumpbox-ip>
SSH Key: ~/.ssh/your-key.pem

# One-Liner Setup
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip> "sudo tee /etc/systemd/resolved.conf.d/kube-dns.conf > /dev/null <<EOF
[Resolve]
DNS=52.214.59.204 52.209.78.3 52.214.106.159
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
Cache=yes
DNSStubListener=yes
EOF
sudo systemctl restart systemd-resolved"
```
