# Staged Kubernetes Upgrade: 1.33 → 1.35

## Status

**Current Cluster Version:** 1.35 ✅  
**Upgrade Complete:** 2026-05-23  
**Next Action:** Monitor for 1.36 availability (expected ~Q3 2026)

---

## Overview

**AWS EKS Limitation:** EKS only allows upgrading **one minor version at a time**.

You cannot jump from 1.33 → 1.35 directly. The upgrade must be staged:
1. **Stage 1:** 1.33 → 1.34
2. **Stage 2:** 1.34 → 1.35

---

## Stage 1: Upgrade to Kubernetes 1.34

### Current Configuration

```hcl
# terraform.tfvars
kubernetes_version = "1.34"  # Stage 1 target
```

### Addon Versions for K8s 1.34

| Addon | Version | Status |
|-------|---------|--------|
| vpc-cni | v1.21.2-eksbuild.2 | ✅ Compatible with 1.34 & 1.35 |
| coredns | v1.13.2-eksbuild.7 | ✅ K8s 1.34 |
| kube-proxy | v1.34.6-eksbuild.8 | ✅ K8s 1.34 |
| aws-ebs-csi-driver | v1.60.0-eksbuild.1 | ✅ Compatible with 1.34 & 1.35 |

### Deployment Steps

```bash
# 1. Verify current version
aws eks describe-cluster \
  --name jph-demo-cluster \
  --region eu-west-1 \
  --query 'cluster.version' \
  --output text
# Expected: 1.33

# 2. Apply Stage 1 upgrade
cd tf
terraform init -upgrade
terraform plan

# Review the plan - should show:
# - EKS cluster version: 1.33 → 1.34
# - coredns addon: will update
# - kube-proxy addon: will update

terraform apply

# 3. Wait for upgrade to complete (~15 minutes)
# The cluster remains available during control plane upgrade

# 4. Verify upgrade completed
aws eks describe-cluster \
  --name jph-demo-cluster \
  --region eu-west-1 \
  --query 'cluster.version' \
  --output text
# Expected: 1.34

# 5. Check addon status
aws eks list-addons \
  --cluster-name jph-demo-cluster \
  --region eu-west-1

# Each addon should show status: ACTIVE

# 6. Verify nodes are ready
kubectl get nodes
# All nodes should be Ready

# 7. Check critical pods
kubectl get pods -n kube-system
kubectl get pods -n karpenter
kubectl get pods -n confluent
```

### Expected Timeline

| Step | Duration | Notes |
|------|----------|-------|
| Control Plane Upgrade | ~10-15 min | Non-disruptive |
| Addon Updates | ~3-5 min | Rolling updates |
| Node Refresh | ~10-15 min | Karpenter will gradually replace nodes |
| **Total** | **~25-35 min** | Cluster remains operational |

---

## Stage 2: Upgrade to Kubernetes 1.35

### Pre-requisites

- ✅ Stage 1 complete (cluster on 1.34)
- ✅ All nodes running
- ✅ All pods healthy
- ✅ No errors in addon status

### Configuration Changes

```bash
# 1. Update terraform.tfvars
sed -i '' 's/kubernetes_version = "1.34"/kubernetes_version = "1.35"/' terraform.tfvars

# Or manually edit:
# terraform.tfvars:
#   kubernetes_version = "1.35"
```

### Addon Versions for K8s 1.35

Update `main.tf` with these versions:

```hcl
# main.tf

resource "aws_eks_addon" "coredns" {
  addon_version = "v1.14.2-eksbuild.4"  # Updated for 1.35
}

resource "aws_eks_addon" "kube-proxy" {
  addon_version = "v1.35.3-eksbuild.8"  # Updated for 1.35
}

# vpc-cni and aws-ebs-csi-driver remain the same (already latest)
```

### Deployment Steps

```bash
# 1. Edit configuration files
# Update terraform.tfvars:
kubernetes_version = "1.35"

# Update main.tf addon versions (see above)

# 2. Apply Stage 2 upgrade
terraform plan

# Review the plan - should show:
# - EKS cluster version: 1.34 → 1.35
# - coredns addon: v1.13.2 → v1.14.2
# - kube-proxy addon: v1.34.6 → v1.35.3

terraform apply

# 3. Wait for upgrade to complete (~15 minutes)

# 4. Verify final version
aws eks describe-cluster \
  --name jph-demo-cluster \
  --region eu-west-1 \
  --query 'cluster.version' \
  --output text
# Expected: 1.35

# 5. Verify all addons updated
aws eks describe-addon \
  --cluster-name jph-demo-cluster \
  --addon-name coredns \
  --region eu-west-1 \
  --query 'addon.addonVersion'
# Expected: v1.14.2-eksbuild.4

# 6. Final health check
kubectl get nodes
kubectl get pods -A
kubectl get nodepools
```

### Expected Timeline

| Step | Duration | Notes |
|------|----------|-------|
| Control Plane Upgrade | ~10-15 min | Non-disruptive |
| Addon Updates | ~3-5 min | Rolling updates |
| Node Refresh | ~10-15 min | Karpenter replaces nodes |
| **Total** | **~25-35 min** | Cluster remains operational |

---

## Complete Upgrade Summary

### Timeline

| Stage | From | To | Duration |
|-------|------|----|---------| 
| Stage 1 | 1.33 | 1.34 | ~25-35 min |
| *Wait/Verify* | - | - | ~5-10 min |
| Stage 2 | 1.34 | 1.35 | ~25-35 min |
| **Total** | **1.33** | **1.35** | **~60-80 min** |

### Version Changes

```
Kubernetes:    1.33 → 1.34 → 1.35
CoreDNS:       1.12.4 → 1.13.2 → 1.14.2
kube-proxy:    (unversioned) → 1.34.6 → 1.35.3
vpc-cni:       1.21.1 → 1.21.2 (single update, both stages)
ebs-csi:       (unversioned) → 1.60.0 (single update, both stages)
Karpenter:     1.8.2 → 1.12.1 (single update, both stages)
Confluent Ops: (latest) → 0.1351.59 (single update, both stages)
```

---

## Verification Checklist

### After Stage 1 (K8s 1.34)

- [ ] Cluster version is 1.34
- [ ] All nodes are Ready
- [ ] CoreDNS pods running (v1.13.2)
- [ ] kube-proxy version matches (v1.34.6)
- [ ] All Kafka brokers accessible
- [ ] DNS resolution working from jumpbox
- [ ] No errors in `kubectl get events -A`

### After Stage 2 (K8s 1.35)

- [ ] Cluster version is 1.35
- [ ] All nodes are Ready
- [ ] CoreDNS pods running (v1.14.2)
- [ ] kube-proxy version matches (v1.35.3)
- [ ] All Kafka brokers accessible
- [ ] DNS resolution working from jumpbox
- [ ] Karpenter functioning (check nodepools)
- [ ] No errors in cluster

---

## Rollback (If Needed)

### If Stage 1 Fails

**EKS clusters cannot be downgraded.** However, you can:

1. Fix the issue and re-apply
2. If critical, restore from backup and recreate

### If Stage 2 Fails

1. Cluster will remain on 1.34 (stable)
2. Fix the issue and re-attempt Stage 2
3. 1.34 is fully supported until 2027

---

## Automated Script (Optional)

```bash
#!/bin/bash
# staged-k8s-upgrade.sh

set -euo pipefail

CLUSTER_NAME="jph-demo-cluster"
REGION="eu-west-1"

echo "=== EKS Staged Upgrade: 1.33 → 1.34 → 1.35 ==="

# Stage 1: Upgrade to 1.34
echo ""
echo "Stage 1: Upgrading to Kubernetes 1.34..."
echo "kubernetes_version = \"1.34\"" > terraform.tfvars.stage1
sed -i '' 's/kubernetes_version = .*/kubernetes_version = "1.34"/' terraform.tfvars

terraform apply -auto-approve

echo "Waiting for cluster to stabilize (60 seconds)..."
sleep 60

CURRENT_VERSION=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.version' --output text)
echo "Current version: $CURRENT_VERSION"

if [ "$CURRENT_VERSION" != "1.34" ]; then
    echo "ERROR: Stage 1 failed. Cluster is still on $CURRENT_VERSION"
    exit 1
fi

echo "✓ Stage 1 complete: Cluster upgraded to 1.34"

# Wait before Stage 2
echo ""
read -p "Press Enter to continue to Stage 2 (upgrade to 1.35)..."

# Stage 2: Upgrade to 1.35
echo ""
echo "Stage 2: Upgrading to Kubernetes 1.35..."

# Update addon versions in main.tf
sed -i '' 's/v1.13.2-eksbuild.7/v1.14.2-eksbuild.4/' main.tf  # coredns
sed -i '' 's/v1.34.6-eksbuild.8/v1.35.3-eksbuild.8/' main.tf  # kube-proxy

sed -i '' 's/kubernetes_version = "1.34"/kubernetes_version = "1.35"/' terraform.tfvars

terraform apply -auto-approve

echo "Waiting for cluster to stabilize (60 seconds)..."
sleep 60

FINAL_VERSION=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.version' --output text)
echo "Final version: $FINAL_VERSION"

if [ "$FINAL_VERSION" != "1.35" ]; then
    echo "ERROR: Stage 2 failed. Cluster is on $FINAL_VERSION"
    exit 1
fi

echo ""
echo "✓ ✓ ✓ UPGRADE COMPLETE ✓ ✓ ✓"
echo "Cluster successfully upgraded: 1.33 → 1.34 → 1.35"
echo ""
echo "Verify with: kubectl get nodes && kubectl get pods -A"
```

---

## Important Notes

### EKS Upgrade Policy

- **One version at a time:** You can only upgrade one Kubernetes minor version at a time
- **No downgrades:** EKS clusters cannot be downgraded
- **Version support:** Each EKS version is supported for ~14 months after release
- **Forced upgrades:** AWS will eventually force-upgrade unsupported versions

### Best Practices

1. **Test in non-production first** (if applicable)
2. **Backup before upgrading** (state file, critical data)
3. **Upgrade during maintenance window** (low-traffic period)
4. **Monitor during upgrade** (watch pods, nodes, metrics)
5. **Have rollback plan** (though downgrade not possible, know recovery steps)

### Support Timeline

| Version | Upstream Release | Amazon EKS Release | End of Standard Support | End of Extended Support |
|---------|------------------|--------------------|-----------------------|------------------------|
| 1.33 | April 23, 2025 | May 29, 2025 | July 29, 2026 | July 29, 2027 |
| 1.34 | August 27, 2025 | October 2, 2025 | December 2, 2026 | December 2, 2027 |
| 1.35 | December 17, 2025 | January 27, 2026 | March 27, 2027 | March 27, 2028 |

---

**Upgrade Date:** 2026-05-23  
**Cluster:** jph-demo-cluster  
**Region:** eu-west-1  
**Strategy:** Staged (1.33→1.34→1.35)
