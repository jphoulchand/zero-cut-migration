# DNS Architecture - Jumpbox to Kafka Cluster

## Overview

**Problem**: Jumpbox (separate VPC) needs to resolve Kubernetes service names like `kafka.confluent.svc.cluster.local`

**Solution**: dnsmasq on jumpbox forwards queries to EKS system nodes via NodePort

**Cost**: FREE (no NLB required)

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Jumpbox (10.19.192.0/24)                                    │
│                                                              │
│  Application/User                                            │
│       │                                                      │
│       │ dig kafka.confluent.svc.cluster.local               │
│       ↓                                                      │
│  systemd-resolved (127.0.0.53)                              │
│       │                                                      │
│       │ DNS=127.0.0.1                                       │
│       ↓                                                      │
│  dnsmasq (127.0.0.1:53)                                     │
│       │                                                      │
│       │ server=/cluster.local/10.19.1.230#30053            │
│       │ server=/cluster.local/10.19.2.205#30053            │
│       ↓                                                      │
└───────┼──────────────────────────────────────────────────────┘
        │
        │ VPC Peering
        ↓
┌─────────────────────────────────────────────────────────────┐
│ EKS VPC (10.19.0.0/18)                                      │
│                                                              │
│  System Nodes:                                               │
│    - 10.19.1.230:30053 ──┐                                  │
│    - 10.19.2.205:30053 ──┼─→ kube-dns-external (NodePort)  │
│                           │                                  │
│                           ↓                                  │
│                      kube-dns Service                        │
│                       (ClusterIP: 172.20.0.10:53)           │
│                           │                                  │
│                           ↓                                  │
│                      CoreDNS Pods                            │
│                       - 10.19.1.49:53                       │
│                       - 10.19.2.32:53                       │
│                           │                                  │
│                           ↓                                  │
│                      Returns: kafka pod IPs                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Components

### 1. CoreDNS Pods (kube-system namespace)

- **Type**: Kubernetes DNS service
- **Replicas**: 2
- **IPs**: 10.19.1.49, 10.19.2.32 (pod IPs, can change)
- **Purpose**: Resolves cluster.local domains

### 2. kube-dns Service (ClusterIP)

- **Type**: ClusterIP
- **IP**: 172.20.0.10
- **Ports**: 53/UDP, 53/TCP
- **Accessibility**: Cluster-internal only (not routable from jumpbox)

### 3. kube-dns-external Service (NodePort)

- **Type**: NodePort
- **Selector**: k8s-app=kube-dns
- **Ports**:
  - 53/UDP → NodePort 30053/UDP
  - 53/TCP → NodePort 30053/TCP
- **Purpose**: Exposes CoreDNS to external networks via system nodes

### 4. System Nodes

- **Count**: 2 (t3.large, on-demand)
- **IPs**: 10.19.1.230, 10.19.2.205
- **Stability**: Persistent (not managed by Karpenter)
- **Purpose**: Stable endpoints for NodePort access

### 5. dnsmasq (Jumpbox)

- **Port**: 127.0.0.1:53
- **Config**: `/etc/dnsmasq.d/kube-dns.conf`
- **Purpose**: Forwards cluster.local queries to system nodes on port 30053
- **Why needed**: systemd-resolved doesn't support custom ports in DNS= directive

### 6. systemd-resolved (Jumpbox)

- **Config**: `/etc/systemd/resolved.conf.d/kube-dns.conf`
- **DNS Server**: 127.0.0.1 (dnsmasq)
- **Search Domains**: confluent.svc.cluster.local, svc.cluster.local, cluster.local

## DNS Query Flow

Example: `dig kafka.confluent.svc.cluster.local`

1. **Application** sends query to systemd-resolved (127.0.0.53)
2. **systemd-resolved** forwards to dnsmasq (127.0.0.1:53) based on domain match
3. **dnsmasq** checks if domain matches `/cluster.local/` pattern
4. **dnsmasq** forwards to system node (10.19.1.230:30053 or 10.19.2.205:30053)
5. **NodePort** routes to kube-dns Service (172.20.0.10:53)
6. **kube-dns Service** load-balances to CoreDNS pods
7. **CoreDNS** resolves the service name → returns Kafka pod IPs
8. Response flows back through the chain

## Configuration Files

### Terraform (Infrastructure)

```hcl
# tf/dns.tf
resource "kubernetes_service_v1" "kube_dns_external" {
  metadata {
    name      = "kube-dns-external"
    namespace = "kube-system"
  }
  spec {
    type = "NodePort"
    selector = {
      "k8s-app" = "kube-dns"
    }
    port {
      name        = "dns-udp"
      port        = 53
      target_port = 53
      protocol    = "UDP"
      node_port   = 30053
    }
    port {
      name        = "dns-tcp"
      port        = 53
      target_port = 53
      protocol    = "TCP"
      node_port   = 30053
    }
  }
}
```

### dnsmasq (Jumpbox)

```bash
# /etc/dnsmasq.d/kube-dns.conf
server=/cluster.local/10.19.1.230#30053
server=/svc.cluster.local/10.19.1.230#30053
server=/confluent.svc.cluster.local/10.19.1.230#30053
server=/cluster.local/10.19.2.205#30053
server=/svc.cluster.local/10.19.2.205#30053
server=/confluent.svc.cluster.local/10.19.2.205#30053

cache-size=1000
listen-address=127.0.0.1
bind-interfaces
```

### systemd-resolved (Jumpbox)

```ini
# /etc/systemd/resolved.conf.d/kube-dns.conf
[Resolve]
DNS=127.0.0.1
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
Cache=yes
DNSStubListener=yes
```

## Benefits

### vs NLB Approach
- **Cost**: FREE (saves ~$16/month)
- **Simplicity**: No load balancer to manage
- **Performance**: Direct node access, fewer hops
- **Reliability**: System nodes are stable, don't scale down

### vs Direct CoreDNS Pod IPs
- **Stability**: Pod IPs change on restart, system node IPs don't
- **Routing**: Pod IPs use cluster networking, not directly routable
- **HA**: Automatically fails over between system nodes

### vs Manual DNS Updates
- **Automation**: No manual IP updates needed
- **Resilience**: Survives CoreDNS pod restarts
- **Consistency**: Single source of truth

## Limitations & Considerations

1. **System Node Dependency**: If system nodes are replaced, IPs may change
   - **Mitigation**: System nodes are on-demand, rarely replaced
   - **Fix**: Update dnsmasq config with new IPs (one-time operation)

2. **NodePort Range**: 30000-32767
   - Using 30053 (outside typical service range)
   - No conflict with other services

3. **UDP Only for Large Responses**: 
   - TCP fallback supported (both protocols exposed)
   - Handles large DNS responses (e.g., many Kafka broker IPs)

4. **dnsmasq Required**:
   - Small overhead (minimal resource usage)
   - Standard package in RHEL/Amazon Linux

5. **VPC Peering Required**:
   - Already in place for jumpbox access
   - No additional configuration needed

## Troubleshooting

### DNS Not Resolving

```bash
# Check dnsmasq is running
systemctl status dnsmasq

# Check dnsmasq logs
journalctl -u dnsmasq -n 50

# Test NodePort directly
dig @10.19.1.230 -p 30053 kafka.confluent.svc.cluster.local +short

# Check systemd-resolved config
resolvectl status

# Test local dnsmasq
dig @127.0.0.1 kafka.confluent.svc.cluster.local +short
```

### NodePort Not Responding

```bash
# From local machine (not jumpbox)
kubectl get svc kube-dns-external -n kube-system

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check system nodes
kubectl get nodes --selector='!karpenter.sh/nodepool'

# Test from within cluster
kubectl run -it --rm dns-test --image=busybox --restart=Never -- \
  nslookup kafka.confluent.svc.cluster.local
```

### System Node IPs Changed

```bash
# Get new IPs
kubectl get nodes --selector='!karpenter.sh/nodepool' \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'

# Update dnsmasq config with new IPs
sudo vi /etc/dnsmasq.d/kube-dns.conf

# Restart dnsmasq
sudo systemctl restart dnsmasq
```

## Verification

### Complete Test Suite

```bash
# 1. Check dnsmasq is running
systemctl status dnsmasq

# 2. Test NodePort directly
dig @10.19.1.230 -p 30053 kafka.confluent.svc.cluster.local +short

# 3. Test via dnsmasq
dig @127.0.0.1 kafka.confluent.svc.cluster.local +short

# 4. Test via systemd-resolved (normal usage)
dig kafka.confluent.svc.cluster.local +short

# 5. Test all Kafka brokers
for i in {0..11}; do
  echo "kafka-$i: $(dig kafka-$i.kafka.confluent.svc.cluster.local +short)"
done

# 6. Test KRaft controllers
dig kraftcontroller.confluent.svc.cluster.local +short

# 7. Verify search domains
dig kafka +short
# Should resolve to kafka.confluent.svc.cluster.local
```

## Maintenance

### Regular Checks (Optional)

```bash
# Monthly: Verify system node IPs haven't changed
kubectl get nodes --selector='!karpenter.sh/nodepool' \
  -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}'

# Expected: 10.19.1.230 10.19.2.205
```

### After EKS Cluster Changes

If you recreate or upgrade the EKS cluster:
1. System node IPs may change
2. Re-run `tf/scripts/setup-jumpbox-dns-nodeport.sh` on jumpbox
3. Or manually update `/etc/dnsmasq.d/kube-dns.conf`

## Alternatives Considered

| Approach | Cost | Complexity | Stability | Selected |
|----------|------|------------|-----------|----------|
| NLB with LoadBalancer service | $16/mo | Medium | High | ❌ Too expensive |
| Direct CoreDNS pod IPs | Free | Low | Low | ❌ IPs change |
| Route53 Resolver | $180/mo | High | High | ❌ Very expensive |
| **NodePort + dnsmasq** | **Free** | **Low** | **High** | **✅ Winner** |

## References

- [Kubernetes NodePort Service](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)
- [dnsmasq Documentation](http://www.thekelleys.org.uk/dnsmasq/doc.html)
- [systemd-resolved](https://www.freedesktop.org/software/systemd/man/systemd-resolved.service.html)
- Terraform: `tf/dns.tf`
- Setup Script: `tf/scripts/setup-jumpbox-dns-nodeport.sh`
