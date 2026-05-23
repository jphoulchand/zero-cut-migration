# Confluent Platform on AWS with Karpenter

Production-ready deployment of Confluent Platform (Apache Kafka) on AWS using Confluent for Kubernetes (CFK) operator with Karpenter for cost-optimized node provisioning.

## Overview

This project demonstrates a highly available, cost-optimized Kafka deployment on AWS:

- **EKS 1.35** cluster with Karpenter-managed spot instances
- **12 Kafka brokers** (ARM64 t4g/c6g/m6g instances across 3 AZs)
- **5 KRaft controllers** (Kafka without ZooKeeper)
- **mTLS authentication** with auto-generated certificates
- **NodePort DNS** for cross-VPC service discovery (no NLB cost)
- **~$364/month** total infrastructure cost

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ EKS Cluster (10.19.0.0/18)                                  │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │ KRaft Controllers│  │  Kafka Brokers   │                │
│  │   5 replicas     │  │   12 replicas    │                │
│  │  (spot ARM64)    │  │  (spot ARM64)    │                │
│  └──────────────────┘  └──────────────────┘                │
│                                                              │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │ Schema Registry  │  │  Kafka Connect   │                │
│  │   2 replicas     │  │   2 replicas     │                │
│  └──────────────────┘  └──────────────────┘                │
│                                                              │
└──────────────────────────────────────────────────────────────┘
         ↑ VPC Peering
┌──────────────────────────────────────────────────────────────┐
│ Jumpbox VPC (10.19.192.0/24)                                │
│  - DNS via NodePort (dnsmasq → System Nodes:30053)         │
│  - Kafka CLI tools, kubectl, helm                           │
└──────────────────────────────────────────────────────────────┘
```

## Directory Structure

```
.
├── tf/                      # Terraform infrastructure
│   ├── main.tf              # EKS cluster, Karpenter, VPC
│   ├── jumpbox.tf           # Jump server configuration
│   ├── dns.tf               # NodePort DNS setup
│   ├── scripts/             # Setup and validation scripts
│   └── README.md            # Terraform documentation
│
├── kafka/                   # Kubernetes manifests
│   ├── kafka-core.yaml      # KRaft controllers + brokers
│   ├── kafka-auxiliary.yaml # Schema Registry, Connect
│   ├── README.md            # Deployment guide
│   ├── QUICKSTART.md        # 5-minute deployment
│   └── DNS-ARCHITECTURE.md  # DNS resolution details
│
└── README.md                # This file
```

## Quick Start

### Prerequisites

- AWS account with appropriate credentials
- Terraform 1.5+
- kubectl
- Helm 3
- SSH key pair

### 1. Deploy Infrastructure

```bash
cd tf
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

**Time:** ~20 minutes

### 2. Deploy Kafka

```bash
# Configure kubectl
aws eks update-kubeconfig --name <project-name>-cluster --region eu-west-1

# Install CFK operator
kubectl create namespace confluent
kubectl config set-context --current --namespace confluent
helm repo add confluentinc https://packages.confluent.io/helm
helm install confluent-operator confluentinc/confluent-for-kubernetes

# Deploy Kafka cluster
kubectl apply -f kafka/kafka-core.yaml
kubectl apply -f kafka/kafka-auxiliary.yaml
```

**Time:** ~10 minutes

### 3. Verify Deployment

```bash
# Check all pods
kubectl get pods -n confluent

# Test from jumpbox
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>
dig kafka.confluent.svc.cluster.local +short
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 --list
```

## Key Features

### Cost Optimization

- **Karpenter**: Automatic spot instance provisioning
- **ARM64 instances**: t4g/c6g/m6g families (cheaper than x86)
- **Spot-only**: ~70% cost savings vs on-demand
- **NodePort DNS**: FREE (no NLB cost of $16/month)

**Total:** ~$364/month for 12-broker production cluster

### High Availability

- **3 AZs**: Brokers and controllers distributed across availability zones
- **Preferred anti-affinity**: Flexible placement with zone distribution
- **12000 vCPU limit per AZ**: Room for scaling
- **System nodes**: Stable on-demand nodes for critical services

### Security

- **mTLS authentication**: Mutual TLS between all components
- **TLS 1.3**: Modern encryption protocol
- **Auto-generated certificates**: CFK operator manages certificate lifecycle
- **VPC isolation**: Separate VPCs for EKS and jumpbox

## Documentation

- **[tf/README.md](tf/README.md)** - Terraform infrastructure guide
- **[kafka/README.md](kafka/README.md)** - Complete Kafka deployment guide
- **[kafka/QUICKSTART.md](kafka/QUICKSTART.md)** - Fast 5-minute deployment
- **[kafka/DNS-ARCHITECTURE.md](kafka/DNS-ARCHITECTURE.md)** - DNS resolution details
- **[tf/STAGED-UPGRADE.md](tf/STAGED-UPGRADE.md)** - EKS upgrade procedures

## Deployment Status

| Component | Status | Replicas | Instance Type |
|-----------|--------|----------|---------------|
| EKS Cluster | ✅ Running | - | 1.35 |
| KRaft Controllers | ✅ Running | 5/5 | t4g.large (spot) |
| Kafka Brokers | ✅ Running | 12/12 | t4g/c6g/m6g (spot) |
| Schema Registry | ✅ Running | 2/2 | t4g.medium (spot) |
| Kafka Connect | ✅ Running | 2/2 | t4g.medium (spot) |
| DNS Resolution | ✅ Working | - | NodePort 30053 |

## Technology Stack

- **Kubernetes**: EKS 1.35
- **Kafka**: Confluent Platform 8.2.1
- **Operator**: Confluent for Kubernetes 3.2.2
- **Node Provisioner**: Karpenter 1.1.0
- **Infrastructure**: Terraform 1.5+
- **Architecture**: KRaft (no ZooKeeper)

## Cost Breakdown

| Component | Monthly Cost |
|-----------|--------------|
| EKS Control Plane | $73 |
| System Nodes (1x t3.large) | $60 |
| Kafka Brokers (12x spot) | $85 |
| KRaft Controllers (5x spot) | $35 |
| Schema Registry (2x spot) | $14 |
| Kafka Connect (2x spot) | $14 |
| VPC/Networking | $15 |
| Jumpbox (t3.medium) | $8 |
| **Total** | **~$304/month** |

## Troubleshooting

See detailed troubleshooting guides:
- [kafka/README.md#troubleshooting](kafka/README.md#troubleshooting)
- [kafka/DNS-ARCHITECTURE.md#troubleshooting](kafka/DNS-ARCHITECTURE.md#troubleshooting)

## Contributing

This is a demo project. For production use:
1. Review security settings
2. Adjust instance types and counts
3. Configure monitoring and alerting
4. Set up backup and disaster recovery

## License

This project is for demonstration purposes.
