# DNS Setup for Jumpbox

## Overview

The jumpbox needs to resolve Kubernetes cluster DNS names (like `kafka.confluent.svc.cluster.local`) to access Kafka from outside the cluster. This is achieved via:

1. **NodePort service** exposing CoreDNS on port 30053
2. **System node IPs** configured in the jumpbox's DNS resolver
3. **VPC peering** allowing jumpbox to reach system nodes

## Two-Stage Terraform Apply

Due to Terraform's dependency resolution, the DNS configuration requires a **two-stage apply process**:

### Stage 1: Initial Infrastructure (First Apply)

```bash
cd tf
terraform apply
```

**What happens:**
- EKS cluster created
- System nodes provisioned
- NodePort service created
- Jumpbox launched (without DNS configuration)

**Note:** The output `kube_dns_node_ips` will show `"pending"` because system nodes are being created.

### Stage 2: DNS Configuration (After System Nodes are Running)

Wait ~3-5 minutes for system nodes to finish provisioning, then:

```bash
# Get the system node IPs
terraform output kube_dns_node_ips

# Output will show something like:
# "10.19.1.123 10.19.2.234"

# Re-apply to update jumpbox DNS configuration
terraform apply -refresh-only
terraform apply
```

**What happens:**
- Terraform detects running system nodes
- Updates `kube_dns_node_ips` output with actual IPs
- Jumpbox user_data can now reference real IPs (if recreated)

## Manual DNS Configuration (Alternative)

If you don't want to wait for the second apply or the jumpbox is already running, configure DNS manually on the jumpbox:

```bash
# SSH to jumpbox
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>

# Get system node IPs from Terraform output
# Example: SYSTEM_NODE_IPS="10.19.1.123 10.19.2.234"

# Configure systemd-resolved
sudo tee /etc/systemd/resolved.conf.d/kubernetes.conf <<EOF
[Resolve]
DNS=$SYSTEM_NODE_IPS
Domains=~cluster.local ~svc.cluster.local ~confluent.svc.cluster.local
EOF

# Restart systemd-resolved
sudo systemctl restart systemd-resolved

# Verify configuration
resolvectl status

# Test DNS resolution
dig @10.19.1.123 -p 30053 kafka.confluent.svc.cluster.local +short
```

## Automated Script

The `scripts/setup_dns.sh` script is automatically run via user_data on jumpbox creation (Stage 2). It:

1. Detects if system node IPs are available
2. Configures systemd-resolved with those IPs
3. Sets up DNS domains for cluster.local resolution
4. Verifies the configuration

## Troubleshooting

### DNS resolution not working on jumpbox

```bash
# 1. Check systemd-resolved status
resolvectl status

# 2. Verify system node IPs are correct
terraform output kube_dns_node_ips

# 3. Test NodePort directly from jumpbox
dig @<system-node-ip> -p 30053 kubernetes.default.svc.cluster.local +short

# 4. Check VPC peering routes
ping <system-node-ip>

# 5. Verify NodePort service exists
kubectl get svc -n kube-system kube-dns-external
```

### Output shows "pending"

This is normal on first apply. Wait for system nodes to start:

```bash
# Check system nodes status
kubectl get nodes -l node-type=system

# When nodes are Ready, refresh Terraform
terraform apply -refresh-only
```

### Jumpbox DNS not auto-configured

The jumpbox `user_data` has `ignore_changes` to prevent recreation on updates. To apply new DNS config:

1. **Option A: Recreate jumpbox**
   ```bash
   terraform taint aws_instance.jump_box
   terraform apply
   ```

2. **Option B: Manual configuration** (see above)

3. **Option C: Run script manually**
   ```bash
   scp scripts/setup_dns.sh ec2-user@<jumpbox-ip>:~/
   ssh ec2-user@<jumpbox-ip>
   SYSTEM_NODE_IPS="10.19.1.123 10.19.2.234" bash setup_dns.sh
   ```

## Why Two Stages?

Terraform's `for_each` requires all values to be known at **plan time**. Since system node IPs only exist after EC2 instances are running (apply time), we use a conditional approach:

1. **First apply:** System nodes don't exist → `system_node_ips = "pending"`
2. **Second apply:** System nodes running → `system_node_ips = "10.19.1.123 10.19.2.234"`

The alternative (removed) approach used `data.aws_instance` with `for_each` on instance IDs, which caused the error:

```
Error: Invalid for_each argument
The "for_each" set includes values derived from resource attributes that 
cannot be determined until apply
```

## Architecture

```
┌─────────────────────────────────────────┐
│ Jumpbox VPC (10.19.192.0/24)           │
│                                         │
│  systemd-resolved                       │
│    ↓ DNS query for *.cluster.local     │
│  10.19.1.123:30053 (system node 1)     │
│  10.19.2.234:30053 (system node 2)     │
└─────────────────────────────────────────┘
         │ VPC Peering
         ↓
┌─────────────────────────────────────────┐
│ EKS VPC (10.19.0.0/18)                 │
│                                         │
│  System Nodes (t3.large)               │
│    ↓ NodePort 30053                    │
│  kube-dns-external Service             │
│    ↓ ClusterIP                         │
│  CoreDNS Pods                          │
└─────────────────────────────────────────┘
```

## Cost Impact

- **NodePort approach:** FREE (no additional AWS charges)
- **Alternative (NLB):** ~$16/month

By using NodePort, we save on NLB costs while maintaining stable DNS resolution.
