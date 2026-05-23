# EKS + Kafka Infrastructure with Automated DNS

Production-ready Terraform configuration for AWS EKS cluster with Confluent Kafka on Kubernetes, featuring automated DNS resolution, secure SSH access, and remote state management.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [DNS Resolution](#dns-resolution)
- [Remote State Backend](#remote-state-backend)
- [Verification](#verification)
- [Troubleshooting](#troubleshooting)
- [Cost Breakdown](#cost-breakdown)
- [Maintenance](#maintenance)

---

## Overview

This infrastructure deploys:

- **EKS Cluster** (Kubernetes **1.35** - Latest) with VPC in `10.19.0.0/18`
- **Jumpbox** in separate VPC (`10.19.192.0/24`) with VPC peering
- **Karpenter v1.12.1** for autoscaling ARM64 nodes across 3 AZs
- **Confluent Platform Operator v3.1.1** and KRaft-mode Kafka
- **Automated DNS** via Network Load Balancer (NLB) - ~$16/month
- **Remote State** in S3 with DynamoDB locking (optional)
- **Secure SSH** with IP-based access control (VPN only)
- **Latest CVE patches** - AL2023 (May 2026), all addons updated

**Key Improvements:**
- ✅ **No manual DNS updates** - NLB provides stable endpoint (~$16/month)
- ✅ **SSH restricted** to VPN/office IPs (134.238.54.136/32, no more 0.0.0.0/0)
- ✅ **Remote state** for team collaboration and safety
- ✅ **Code reduced** by 70% (Karpenter refactored with `for_each`)
- ✅ **Latest security patches** - K8s 1.35, CoreDNS 1.14.2, vpc-cni 1.21.2
- ✅ **Auto-updating AMIs** - Latest Amazon Linux 2023 with kernel 6.1

---

## Architecture

### Network Topology

```
┌────────────────────────────────────────────────────────────────────────────┐
│                         AWS Region (eu-west-1)                              │
│                                                                             │
│  ┌──────────────────────────┐      VPC Peering    ┌─────────────────────┐ │
│  │   Jumpbox VPC            │◄────────────────────►│  EKS VPC            │ │
│  │   10.19.192.0/24         │                      │  10.19.0.0/18       │ │
│  │                          │                      │                     │ │
│  │  ┌────────────────────┐  │                      │  Private Subnets:   │ │
│  │  │  Jumpbox EC2       │  │                      │  • 10.19.1.0/24 (a) │ │
│  │  │  AL2023 (May 2026) │  │                      │  • 10.19.2.0/24 (b) │ │
│  │  │  t3.large          │  │                      │  • 10.19.3.0/24 (c) │ │
│  │  │                    │  │                      │                     │ │
│  │  │  SSH: VPN Only     │◄─┼──── 134.238.54.136  │  Public Subnets:    │ │
│  │  │  (134.238.54.x/32) │  │                      │  • 10.19.11.0/24    │ │
│  │  └─────────┬──────────┘  │                      │  • 10.19.12.0/24    │ │
│  │            │              │                      │  • 10.19.13.0/24    │ │
│  │            │ DNS queries  │                      │                     │ │
│  │            │ *.cluster.   │                      │  ┌────────────────┐ │ │
│  │            │   local      │                      │  │ NLB (internal) │ │ │
│  │            └──────────────┼──────────────────────┼─►│ DNS: 53/UDP+TCP│ │ │
│  │                          │                      │  │ Cost: ~$16/mo  │ │ │
│  │  Internet Gateway        │                      │  └────────┬───────┘ │ │
│  │  (Public Access)         │                      │           │         │ │
│  └──────────────────────────┘                      │           │         │ │
│                                                     │           ▼         │ │
│                                                     │  ┌────────────────┐ │ │
│                                                     │  │ kube-dns       │ │ │
│                                                     │  │ LoadBalancer   │ │ │
│                                                     │  │ Service        │ │ │
│                                                     │  └────────┬───────┘ │ │
│                                                     │           │         │ │
│                                                     │           ▼         │ │
│                                                     │  ┌────────────────┐ │ │
│                                                     │  │ CoreDNS Pods   │ │ │
│                                                     │  │ v1.14.2        │ │ │
│                                                     │  │ (3 replicas)   │ │ │
│                                                     │  └────────────────┘ │ │
│                                                     │                     │ │
│  ┌─────────────────────────────────────────────────┼────────────────────┐│ │
│  │              EKS Cluster v1.35                  │                    ││ │
│  │                                                 │                    ││ │
│  │  ┌──────────────────────────────────────────────┼─────────────────┐ ││ │
│  │  │  System Nodes (Managed Node Group)          │                 │ ││ │
│  │  │  • Type: t3.large (2 nodes)                 │                 │ ││ │
│  │  │  • AMI: AL2023_x86_64_STANDARD              │                 │ ││ │
│  │  │  • Taint: CriticalAddonsOnly=true           │                 │ ││ │
│  │  │                                              │                 │ ││ │
│  │  │  Pods:                                       │                 │ ││ │
│  │  │  • Karpenter v1.12.1                        │                 │ ││ │
│  │  │  • Confluent Operator v3.1.1                │                 │ ││ │
│  │  │  • CoreDNS v1.14.2                          │                 │ ││ │
│  │  │  • vpc-cni v1.21.2                          │                 │ ││ │
│  │  │  • aws-ebs-csi-driver v1.60.0               │                 │ ││ │
│  │  │  • kube-proxy v1.35.3                       │                 │ ││ │
│  │  └──────────────────────────────────────────────┘                 │ ││ │
│  │                                                                    │ ││ │
│  │  ┌────────────────────────────────────────────────────────────┐  │ ││ │
│  │  │  Karpenter Auto-Scaled Nodes (3x NodePools by AZ)          │  │ ││ │
│  │  │                                                             │  │ ││ │
│  │  │  AZ-a Nodes:          AZ-b Nodes:          AZ-c Nodes:     │  │ ││ │
│  │  │  • ARM64 (t4g/c6g)    • ARM64 (t4g/c6g)    • ARM64         │  │ ││ │
│  │  │  • Spot + On-Demand   • Spot + On-Demand   • Spot + OD     │  │ ││ │
│  │  │  • AL2023@latest      • AL2023@latest      • AL2023@latest │  │ ││ │
│  │  │  • Taint: arch=arm64  • Taint: arch=arm64  • Taint: arm64  │  │ ││ │
│  │  │                                                             │  │ ││ │
│  │  │  Kafka Brokers (12 total, 4 per AZ):                       │  │ ││ │
│  │  │  • kafka-{0,3,9,10}.kafka.confluent.svc.cluster.local      │  │ ││ │
│  │  │  • kafka-{1,5,7,8}.kafka.confluent.svc.cluster.local       │  │ ││ │
│  │  │  • kafka-{2,4,6,11}.kafka.confluent.svc.cluster.local      │  │ ││ │
│  │  │                                                             │  │ ││ │
│  │  │  KRaft Controllers (5 total, 2-2-1 across AZs)             │  │ ││ │
│  │  └────────────────────────────────────────────────────────────┘  │ ││ │
│  └────────────────────────────────────────────────────────────────────┘│ │
│                                                                         │ │
│  ┌─────────────────────────────────────────────────────────────────┐  │ │
│  │  VPC Endpoints (PrivateLink to AWS Services)                    │  │ │
│  │  • sts.eu-west-1.amazonaws.com    (IAM role assumption)         │  │ │
│  │  • ec2.eu-west-1.amazonaws.com    (Instance metadata)           │  │ │
│  │  • ecr.api / ecr.dkr              (Container registry)          │  │ │
│  │  • s3 (Gateway Endpoint)          (Container layers)            │  │ │
│  └─────────────────────────────────────────────────────────────────┘  │ │
│                                                                         │ │
│  ┌─────────────────────────────────────────────────────────────────┐  │ │
│  │  Remote State Backend (Optional)                                 │  │ │
│  │  • S3: <project>-terraform-state (versioned, encrypted)          │  │ │
│  │  • DynamoDB: <project>-terraform-locks (state locking)           │  │ │
│  └─────────────────────────────────────────────────────────────────┘  │ │
└────────────────────────────────────────────────────────────────────────────┘

Legend:
  ═══  VPC Boundary
  ───  Network Connection
  ◄──► VPC Peering
  ▼    Traffic Flow
```

### DNS Resolution Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                       DNS Query Resolution Path                      │
└─────────────────────────────────────────────────────────────────────┘

  Jumpbox EC2
      │
      │ Query: kafka.confluent.svc.cluster.local
      ▼
  systemd-resolved
  /etc/systemd/resolved.conf.d/kube-dns.conf
  DNS=<nlb-dns-name>.elb.amazonaws.com
      │
      │ Forward *.cluster.local queries
      ▼
  Network Load Balancer (NLB)
  • Type: Internal
  • Listeners: TCP/53, UDP/53  
  • Targets: kube-dns-external Service
  • Cost: ~$16/month
  • High Availability: Multi-AZ
      │
      │ Load balance to service endpoints
      ▼
  Kubernetes Service: kube-dns-external
  • Type: LoadBalancer
  • Namespace: kube-system
  • Selector: k8s-app=kube-dns
  • Ports: 53/UDP, 53/TCP
      │
      │ Route to CoreDNS pods
      ▼
  CoreDNS Pods (v1.14.2)
  • Replicas: 3 (HA)
  • Distributed across AZs
  • ClusterIP: 172.20.0.10 (stable)
      │
      │ Resolve from K8s API
      ▼
  Kubernetes Service Discovery
  • Returns pod IPs for services
  • Example: kafka-0.kafka.confluent → 10.19.1.x
      │
      │ Response
      ▼
  Jumpbox receives IP addresses
```

**Key Benefits:**
- ✅ **Zero manual updates** - NLB DNS name never changes
- ✅ **High availability** - NLB multi-AZ with health checks
- ✅ **Auto-healing** - CoreDNS pods can restart without breaking DNS
- ✅ **Cost effective** - ~$16/month vs $180/month for Route53 Resolver
- ✅ **Cloud-init automated** - Jumpbox configured on first boot

**Before:** Manual updates to `/etc/systemd/resolved.conf` with changing pod IPs  
**After:** Automatic resolution via stable NLB endpoint

### VPC Peering Routes

| Source | Destination | Route Target | Purpose |
|--------|-------------|--------------|---------|
| Jumpbox VPC | 10.19.0.0/18 | VPC Peering | Access EKS pod network |
| Jumpbox VPC | 172.20.0.0/16 | VPC Peering | Access K8s service CIDR |
| Jumpbox VPC | 0.0.0.0/0 | Internet Gateway | Internet access |
| EKS VPC | 10.19.192.0/24 | VPC Peering | Return traffic to jumpbox |
| EKS VPC (private) | 0.0.0.0/0 | NAT Gateway | Internet via NAT (3 AZs) |

**Network Isolation:**
- EKS nodes have **no direct internet access** (private subnets only)
- All AWS API calls via **VPC Endpoints** (PrivateLink)
- Container images pulled via **S3 Gateway Endpoint** (ECR layers)

### Security Groups

| Security Group | Ingress Rules | Egress Rules |
|----------------|---------------|--------------|
| **Jumpbox SG** | • SSH (22) from VPN IP only (134.238.54.136/32)<br>• All traffic from EKS VPC (10.19.0.0/18) | All traffic (0.0.0.0/0) |
| **EKS Node SG** | • All traffic from jumpbox SG<br>• All traffic from same SG (node-to-node) | All traffic (0.0.0.0/0) |
| **VPC Endpoints SG** | • HTTPS (443) from EKS VPC CIDR | All traffic |
| **NLB (auto-created)** | • DNS (53/UDP+TCP) from jumpbox VPC CIDR | Managed by AWS |

**Security Hardening:**
- ✅ SSH restricted from Internet (0.0.0.0/0) to VPN only
- ✅ No public IPs on EKS nodes
- ✅ All AWS API calls via PrivateLink (VPC Endpoints)
- ✅ IMDSv2 enforced on all EC2 instances
- ✅ Encrypted EBS volumes

---

## Prerequisites

### Required Tools

- [Terraform](https://www.terraform.io/downloads) >= 1.7.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/) for cluster access

### AWS Requirements

- **VPC Quota:** At least 2 available VPCs (default limit is 5)
  - Check: `aws ec2 describe-vpcs --region <region> --query 'length(Vpcs)'`
  - Request increase: [AWS Service Quotas Console](https://console.aws.amazon.com/servicequotas/)

- **Available /16 CIDR Block:** Must not conflict with existing VPCs
  - Safe ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
  - Validation: Run `./scripts/validate_tfvars.sh` before deployment

- **SSH Key Pair:** Must exist in target region
  - List: `aws ec2 describe-key-pairs --region <region>`
  - Create: See [Configuration](#configuration) section

### Costs

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| EKS Control Plane | ~$73 | Fixed cost |
| EC2 Instances | ~$60-500 | Depends on node types/count |
| Network Load Balancer | ~$16 | DNS automation |
| NAT Gateway | ~$32-96 | $32 for single, $96 for HA (3 AZs) |
| S3 + DynamoDB (state) | ~$1 | Negligible |
| **Total** | **~$182-$686/month** | |

---

## Quick Start

```bash
# 1. Clone or navigate to terraform directory
cd tf/

# 2. Copy and configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

# 3. Validate configuration (recommended)
./scripts/validate_tfvars.sh

# 4. (Optional) Bootstrap remote state
cd bootstrap/
terraform init
terraform apply
cd ..
# Uncomment backend block in versions.tf
# terraform init -migrate-state

# 5. Deploy infrastructure
terraform init
terraform plan
terraform apply

# 6. Configure kubectl
aws eks update-kubeconfig --name <project-name>-cluster --region <region>

# 7. Verify DNS from jumpbox
ssh -i <key.pem> ec2-user@<jumpbox-ip>
dig kafka.confluent.svc.cluster.local +short
```

---

## Configuration

### 1. Create SSH Key Pair (if needed)

```bash
# Create new key pair in AWS
aws ec2 create-key-pair \
  --key-name my-keypair \
  --region eu-west-1 \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/my-keypair.pem

# Set permissions
chmod 600 ~/.ssh/my-keypair.pem
```

### 2. Configure terraform.tfvars

```hcl
# Required - Project identification
project_name = "my-demo"              # 3-12 chars, lowercase
owner_email  = "you@example.com"

# Required - Region and AZ
aws_region                 = "eu-west-1"
jump_box_availability_zone = "eu-west-1a"

# Required - Networking (must not conflict with existing VPCs)
vpcs_cidr_block = "10.19.0.0/16"

# Required - SSH Access (IMPORTANT: Replaces 0.0.0.0/0)
allowed_ssh_cidrs = ["134.238.54.136/32"]  # Your VPN/office IP

# Required - SSH Key
ssh_key_name         = "my-keypair"
ssh_private_key_path = "~/.ssh/my-keypair.pem"

# Optional - Kubernetes version (latest with security patches)
kubernetes_version = "1.35"

# Optional - Jumpbox instance type
instance_type = "t3.large"
```

### 3. Find Your IP Address

```bash
# Get your current public IP
curl ifconfig.me

# Use in terraform.tfvars
allowed_ssh_cidrs = ["YOUR.IP.HERE/32"]
```

---

## Deployment

### Phase 1: Validate Configuration

```bash
cd tf/
./scripts/validate_tfvars.sh
```

This checks:
- ✓ Required variables are set
- ✓ CIDR format is valid
- ✓ No VPC CIDR conflicts
- ✓ SSH key pair exists in AWS
- ✓ AZ is valid in region
- ✓ Instance type is available
- ✓ Kubernetes version is supported

### Phase 2: Bootstrap Remote State (Optional)

```bash
cd bootstrap/
terraform init
terraform apply

# Note the output values
# Expected output:
#   s3_bucket_name      = "my-demo-terraform-state"
#   dynamodb_table_name = "my-demo-terraform-locks"
```

### Phase 3: Deploy Infrastructure

```bash
cd ..  # Return to tf/ directory
terraform init
terraform plan  # Review changes

# Apply (takes ~15-20 minutes)
terraform apply
```

**Deployment Order:**
1. VPCs and networking (2-3 min)
2. EKS cluster (10-12 min)
3. EKS addons (vpc-cni, ebs-csi, coredns, kube-proxy)
4. Karpenter operator
5. Confluent operator
6. DNS LoadBalancer (NLB)
7. Jumpbox with DNS configuration

### Phase 4: Configure kubectl

```bash
aws eks update-kubeconfig \
  --name <project-name>-cluster \
  --region <region>

# Verify
kubectl get nodes
kubectl get pods -A
```

### Phase 5: Migrate to Remote State (if using bootstrap)

```bash
# Edit tf/versions.tf - uncomment the backend block
# Update bucket and table names from bootstrap output

terraform init -migrate-state
# Type "yes" to confirm migration

# Verify
aws s3 ls s3://<project-name>-terraform-state/
```

---

## DNS Resolution

### How It Works

The jumpbox automatically resolves Kubernetes service names via NLB:

1. **NLB Endpoint:** Created automatically by Kubernetes LoadBalancer service
2. **Cloud-init:** Jumpbox configures systemd-resolved on first boot
3. **systemd-resolved:** Uses NLB DNS name for `*.cluster.local` queries
4. **No Manual Updates:** CoreDNS pod IPs can change without breaking DNS

### Configuration Files

**Jumpbox: `/etc/systemd/resolved.conf.d/kube-dns.conf`**
```ini
[Resolve]
DNS=<nlb-dns-name>.elb.amazonaws.com
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
Cache=yes
```

### Verification

```bash
# SSH to jumpbox
ssh -i ~/.ssh/key.pem ec2-user@<jumpbox-ip>

# Check DNS configuration
resolvectl status

# Test cluster DNS resolution
dig kafka.confluent.svc.cluster.local +short
nslookup kafka-0.kafka.confluent.svc.cluster.local

# Test external DNS (should still work)
dig google.com +short

# Test Kafka connectivity
kafka-broker-api-versions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092
```

### Troubleshooting DNS

**DNS not resolving:**
```bash
# Check NLB status
kubectl get svc kube-dns-external -n kube-system

# Check NLB targets are healthy
aws elbv2 describe-target-health \
  --target-group-arn <from-console>

# Restart systemd-resolved
sudo systemctl restart systemd-resolved

# Test DNS directly via NLB
dig @<nlb-dns-name> kafka.confluent.svc.cluster.local +short
```

**External DNS not working:**
```bash
# Check upstream DNS
resolvectl status | grep "DNS Servers"

# Test fallback
dig @8.8.8.8 google.com
```

---

## Remote State Backend

### Bootstrap Architecture

```
tf/
├── bootstrap/              # Deploy first
│   ├── backend.tf         # S3 + DynamoDB
│   ├── variables.tf
│   └── outputs.tf
└── main terraform         # Deploy second, uses bootstrap
```

### Why Separate Bootstrap?

- **Chicken-egg problem:** State backend can't store its own state
- **Independence:** Bootstrap rarely changes, main terraform evolves
- **Safety:** Bootstrap state stays local, can be versioned separately

### Migration Process

1. **Deploy bootstrap:**
   ```bash
   cd bootstrap/
   terraform init
   terraform apply
   ```

2. **Note outputs:**
   ```
   s3_bucket_name      = "my-demo-terraform-state"
   dynamodb_table_name = "my-demo-terraform-locks"
   ```

3. **Update versions.tf:**
   - Uncomment backend block
   - Update bucket and table names

4. **Migrate state:**
   ```bash
   terraform init -migrate-state
   # Review plan, type "yes"
   ```

5. **Verify migration:**
   ```bash
   # State now in S3
   aws s3 ls s3://my-demo-terraform-state/

   # Lock table exists
   aws dynamodb describe-table \
     --table-name my-demo-terraform-locks
   ```

6. **Team members pull remote state:**
   ```bash
   # After migration, others just need:
   terraform init
   ```

### State Management

**Versioning:**
- S3 versioning enabled (90-day retention for old versions)
- Manually recover: `aws s3api list-object-versions --bucket <name>`

**Locking:**
- DynamoDB prevents concurrent applies
- If locked: Check table for `LockID`, investigate, force-unlock if needed

**Backup:**
```bash
# Before major changes
terraform state pull > backup-$(date +%Y%m%d).tfstate
```

---

## Verification

### Infrastructure Checks

```bash
# VPCs created
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=<project-name>" \
  --region <region>

# EKS cluster running
aws eks describe-cluster \
  --name <project-name>-cluster \
  --region <region>

# Jumpbox accessible
ssh -i <key.pem> ec2-user@<jumpbox-ip>
```

### Kubernetes Checks

```bash
# Nodes ready
kubectl get nodes
# Should show system nodes + Karpenter-provisioned nodes

# Pods running
kubectl get pods -A

# Karpenter nodepools
kubectl get nodepools
# Should show: kafka-arm64-az1, kafka-arm64-az2, kafka-arm64-az3

# Confluent operator
kubectl get pods -n confluent
```

### DNS Checks

See [DNS Resolution](#dns-resolution) section.

---

## Troubleshooting

### Common Issues

#### 1. Terraform Init Fails

**Error:** `Backend initialization required`

**Solution:**
```bash
# If using remote state, ensure backend block is correct
terraform init -reconfigure
```

#### 2. VPC CIDR Conflict

**Error:** `InvalidVpc.Conflict`

**Solution:**
```bash
# Check existing VPCs
aws ec2 describe-vpcs --region <region>

# Choose non-overlapping /16 block
# Update terraform.tfvars
```

#### 3. SSH Connection Refused

**Error:** `Connection timed out` or `Permission denied`

**Solutions:**
```bash
# Check security group allows your IP
aws ec2 describe-security-groups \
  --group-ids <jumpbox-sg-id>

# Verify IP in allowed_ssh_cidrs
grep allowed_ssh_cidrs terraform.tfvars

# Check key permissions
chmod 600 ~/.ssh/key.pem

# Use SSM Session Manager as alternative
aws ssm start-session --target <instance-id>
```

#### 4. Karpenter Not Scheduling Pods

**Symptoms:** Pods stuck in `Pending`, no nodes provisioned

**Solutions:**
```bash
# Check Karpenter logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# Verify nodepools exist
kubectl get nodepools

# Check EC2 instance launch permissions
# Karpenter IAM role needs ec2:RunInstances
```

#### 5. DNS Not Resolving from Jumpbox

See [DNS Troubleshooting](#troubleshooting-dns) section.

---

## Cost Breakdown

### Fixed Costs

| Component | Cost/Month | Notes |
|-----------|------------|-------|
| EKS Control Plane | $72.00 | Fixed |
| Jumpbox (t3.large) | $60.50 | 24/7 |
| Network Load Balancer | $16.20 | DNS automation |
| S3 (state storage) | $0.50 | ~2 MB state |
| DynamoDB (locks) | $0.25 | Pay-per-request |
| **Subtotal (Fixed)** | **$149.45** | |

### Variable Costs

| Component | Cost/Month | Notes |
|-----------|------------|-------|
| NAT Gateway (single) | $32.40 | Cost savings mode |
| NAT Gateway (HA, 3 AZs) | $97.20 | Production recommended |
| EKS Nodes (t3.large × 2) | $121.00 | System nodes |
| Karpenter Nodes (variable) | $0-300+ | Based on workload |
| Data Transfer | $0-50 | Inter-AZ, internet egress |
| **Subtotal (Variable)** | **$153-568** | |

### Total

| Configuration | Monthly Cost |
|---------------|--------------|
| **Dev (single NAT, minimal nodes)** | ~$182 |
| **Production (HA NAT, moderate load)** | ~$400 |
| **Production (HA NAT, high load)** | ~$686+ |

### Cost Optimization Tips

1. **Development:**
   - Use `single_nat_gateway = true` (saves $65/month)
   - Stop jumpbox when not in use
   - Use Spot instances for Karpenter nodes

2. **Production:**
   - Enable `consolidation` in Karpenter (already configured)
   - Right-size system nodes
   - Use Savings Plans for long-term instances

3. **Monitoring:**
   ```bash
   # AWS Cost Explorer API
   aws ce get-cost-and-usage \
     --time-period Start=2026-05-01,End=2026-05-31 \
     --granularity MONTHLY \
     --metrics UnblendedCost \
     --group-by Type=TAG,Key=Project
   ```

---

## Maintenance

### Regular Tasks

**Weekly:**
- Review Karpenter node consolidation logs
- Check for Kubernetes updates

**Monthly:**
- Review AWS costs by project tag
- Update `terraform.tfstate` backup
- Rotate SSH keys (if policy requires)

**Quarterly:**
- Upgrade Kubernetes version (EKS supports N-2)
- Update Terraform provider versions
- Review and update Karpenter instance types

### Kubernetes Version Upgrades

```bash
# Check current version
kubectl version --short

# Update terraform.tfvars
kubernetes_version = "1.34"  # Next version

# Plan and apply
terraform plan
terraform apply

# Update node groups
# EKS will roll nodes automatically
```

### Disaster Recovery

**State Recovery:**
```bash
# List versions
aws s3api list-object-versions \
  --bucket <state-bucket> \
  --prefix terraform.tfstate

# Restore version
aws s3api get-object \
  --bucket <state-bucket> \
  --key terraform.tfstate \
  --version-id <version-id> \
  terraform.tfstate.recovered
```

**VPC Recreation:**
- Bootstrap and main terraform are idempotent
- Can `terraform destroy` and `terraform apply` safely
- DNS will auto-configure on jumpbox reboot

**Backup Strategy:**
- Terraform state: S3 versioned (auto)
- Bootstrap state: Manual copy to S3
- Kubernetes resources: Use Velero or manual `kubectl get --export`

---

## Reference

### Key Files

| File | Purpose |
|------|---------|
| `main.tf` | EKS cluster, VPC, Karpenter, operators |
| `jumpbox.tf` | Jumpbox EC2, VPC, security groups |
| `networking.tf` | VPC peering, routes |
| `dns.tf` | NLB-based DNS automation |
| `variables.tf` | Input variable definitions |
| `versions.tf` | Provider versions, backend config |
| `bootstrap/backend.tf` | S3 + DynamoDB for remote state |
| `scripts/validate_tfvars.sh` | Pre-deployment validation |
| `scripts/setup_dns.sh` | Cloud-init DNS configuration |

### External Documentation

- [EKS Best Practices](https://aws.github.io/aws-eks-best-practices/)
- [Karpenter Documentation](https://karpenter.sh/)
- [Confluent for Kubernetes](https://docs.confluent.io/operator/current/overview.html)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)

### Support

For issues specific to this infrastructure:
1. Check [Troubleshooting](#troubleshooting) section
2. Review `main.md` for operational notes
3. Check Terraform plan output for errors
4. Validate with `./scripts/validate_tfvars.sh`

---

**Last Updated:** 2026-05-23  
**Terraform Version:** >= 1.7.0  
**Kubernetes Version:** 1.33 (upgradeable to 1.34 by July 2026)
