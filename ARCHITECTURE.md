# Architecture Diagram - Confluent Kafka on EKS with Karpenter

## High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              AWS Cloud (eu-west-1)                          │
│                                                                             │
│  ┌───────────────────────────────┐      ┌──────────────────────────────┐  │
│  │   Jumpbox VPC (10.18.64.0/18) │      │  EKS VPC (10.19.0.0/18)      │  │
│  │   ┌─────────────────────┐     │      │                              │  │
│  │   │  Public Subnet      │     │      │  Private Subnets Only        │  │
│  │   │  ┌──────────────┐   │     │      │  (No Internet Gateway)       │  │
│  │   │  │  Jumpbox EC2 │◄──┼─────┼──────┤                              │  │
│  │   │  │  t3.large    │   │     │      │  ┌────────────────────────┐  │  │
│  │   │  │  Public IP   │   │     │ VPC  │  │   EKS Control Plane    │  │  │
│  │   │  └──────────────┘   │     │Peer  │  │   Kubernetes 1.35      │  │  │
│  │   │  - DNS Client       │     │      │  └────────────────────────┘  │  │
│  │   │  - Kafka CLI Tools  │     │      │                              │  │
│  │   └─────────────────────┘     │      │  ┌────────────────────────┐  │  │
│  │                               │      │  │   Worker Nodes         │  │  │
│  └───────────────────────────────┘      │  │   (Karpenter managed)  │  │  │
│           ▲                              │  └────────────────────────┘  │  │
│           │ SSH                          │                              │  │
│           │                              │  ┌────────────────────────┐  │  │
│      Internet                            │  │   VPC Endpoints        │  │  │
│                                          │  │   - ECR API/DKR        │  │  │
│                                          │  │   - EC2, STS           │  │  │
│                                          │  │   - S3 Gateway         │  │  │
│                                          │  └────────────────────────┘  │  │
│                                          └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Detailed EKS Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         EKS Cluster (Kubernetes 1.35)                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                          Availability Zones                         │   │
│  │  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐   │   │
│  │  │   eu-west-1a     │ │   eu-west-1b     │ │   eu-west-1c     │   │   │
│  │  │  (10.19.1.0/24)  │ │  (10.19.2.0/24)  │ │  (10.19.3.0/24)  │   │   │
│  │  │                  │ │                  │ │                  │   │   │
│  │  │  ┌────────────┐  │ │  ┌────────────┐  │ │  ┌────────────┐  │   │   │
│  │  │  │System Node │  │ │                  │ │                  │   │   │
│  │  │  │ t3.large   │  │ │                  │ │                  │   │   │
│  │  │  │ On-Demand  │  │ │                  │ │                  │   │   │
│  │  │  └────────────┘  │ │                  │ │                  │   │   │
│  │  │  - CoreDNS       │ │                  │ │                  │   │   │
│  │  │  - Operators     │ │                  │ │                  │   │   │
│  │  │                  │ │                  │ │                  │   │   │
│  │  │  ┌────────────┐  │ │  ┌────────────┐  │ │  ┌────────────┐  │   │   │
│  │  │  │Kafka Nodes │  │ │  │Kafka Nodes │  │ │  │Kafka Nodes │  │   │   │
│  │  │  │ c6g.xlarge │  │ │  │ c6g.xlarge │  │ │  │ c6g.xlarge │  │   │   │
│  │  │  │ ARM64 Spot │  │ │  │ ARM64 Spot │  │ │  │ ARM64 Spot │  │   │   │
│  │  │  └────────────┘  │ │  └────────────┘  │ │  └────────────┘  │   │   │
│  │  │  - Brokers       │ │  - Brokers       │ │  - Brokers       │   │   │
│  │  │  - Controllers   │ │  - Controllers   │ │  - Controllers   │   │   │
│  │  └──────────────────┘ └──────────────────┘ └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        Kubernetes Namespaces                        │   │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐   │   │
│  │  │kube-system │  │  karpenter │  │ confluent  │  │   default  │   │   │
│  │  │            │  │            │  │            │  │            │   │   │
│  │  │ CoreDNS    │  │ Karpenter  │  │ Confluent  │  │            │   │   │
│  │  │ kube-proxy │  │ Operator   │  │ Operator   │  │            │   │   │
│  │  │ vpc-cni    │  │            │  │ Kafka      │  │            │   │   │
│  │  │ ebs-csi    │  │            │  │ KRaft Ctrl │  │            │   │   │
│  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Kafka Cluster Architecture (Small Deployment)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Confluent Kafka Cluster (KRaft Mode)                     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                        KRaft Controllers (3)                        │   │
│  │  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐   │   │
│  │  │kraftcontroller-0 │ │kraftcontroller-1 │ │kraftcontroller-2 │   │   │
│  │  │   eu-west-1a     │ │   eu-west-1b     │ │   eu-west-1c     │   │   │
│  │  │                  │ │                  │ │                  │   │   │
│  │  │  CPU: 200m-1000m │ │  CPU: 200m-1000m │ │  CPU: 200m-1000m │   │   │
│  │  │  RAM: 2-4Gi      │ │  RAM: 2-4Gi      │ │  RAM: 2-4Gi      │   │   │
│  │  │  Storage: 30Gi   │ │  Storage: 30Gi   │ │  Storage: 30Gi   │   │   │
│  │  └──────────────────┘ └──────────────────┘ └──────────────────┘   │   │
│  │            ▲                    ▲                    ▲              │   │
│  │            └────────────────────┴────────────────────┘              │   │
│  │                     Controller Quorum (mTLS)                        │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                    │                                        │
│                                    │ Metadata Sync                          │
│                                    ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                          Kafka Brokers (4)                          │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │ kafka-0  │  │ kafka-1  │  │ kafka-2  │  │ kafka-3  │           │   │
│  │  │ AZ: 1a   │  │ AZ: 1b   │  │ AZ: 1c   │  │ AZ: 1a   │           │   │
│  │  │          │  │          │  │          │  │          │           │   │
│  │  │CPU: 500m │  │CPU: 500m │  │CPU: 500m │  │CPU: 500m │           │   │
│  │  │   -2000m │  │   -2000m │  │   -2000m │  │   -2000m │           │   │
│  │  │RAM: 4-8Gi│  │RAM: 4-8Gi│  │RAM: 4-8Gi│  │RAM: 4-8Gi│           │   │
│  │  │Vol: 50Gi │  │Vol: 50Gi │  │Vol: 50Gi │  │Vol: 50Gi │           │   │
│  │  │EBS GP3   │  │EBS GP3   │  │EBS GP3   │  │EBS GP3   │           │   │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘           │   │
│  │       │             │             │             │                   │   │
│  │       └─────────────┴─────────────┴─────────────┘                   │   │
│  │              Internal Replication (mTLS, TLS 1.3)                   │   │
│  │              Replication Factor: 3, Min ISR: 2                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                            Operators (2)                            │   │
│  │  ┌────────────────────────┐       ┌────────────────────────┐       │   │
│  │  │  Confluent Operator    │       │  Karpenter Operator    │       │   │
│  │  │  Manages Kafka CRDs    │       │  Node Autoscaling      │       │   │
│  │  │  Version: 3.2.2        │       │  Version: 1.12.1       │       │   │
│  │  └────────────────────────┘       └────────────────────────┘       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Network Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Network Flow Diagram                             │
│                                                                             │
│  ┌─────────────┐                                                            │
│  │   Internet  │                                                            │
│  └──────┬──────┘                                                            │
│         │                                                                   │
│         │ SSH (Port 22)                                                     │
│         ▼                                                                   │
│  ┌─────────────────────────────────────────┐                               │
│  │  Jumpbox VPC (10.18.64.0/18)            │                               │
│  │  ┌───────────────────────────────────┐  │                               │
│  │  │  Jumpbox EC2 (Public Subnet)      │  │                               │
│  │  │  - Public IP: <dynamic>           │  │                               │
│  │  │  - Private IP: 10.18.64.x         │  │                               │
│  │  │  - DNS: dnsmasq → System Nodes    │  │                               │
│  │  └───────────────────────────────────┘  │                               │
│  └──────────┬──────────────────────────────┘                               │
│             │                                                               │
│             │ VPC Peering (10.19.0.0/18 ↔ 10.18.64.0/18)                   │
│             ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  EKS VPC (10.19.0.0/18) - Private Subnets Only                      │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  Private Subnet 1a (10.19.1.0/24)                            │  │   │
│  │  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │  │   │
│  │  │  │ System Node  │  │ kafka-0 pod  │  │kraftctrl-0   │       │  │   │
│  │  │  │              │  │              │  │              │       │  │   │
│  │  │  │ CoreDNS:53   │  │ Internal:9071│  │ Internal:9074│       │  │   │
│  │  │  │ NodePort:    │  │ mTLS enabled │  │ mTLS enabled │       │  │   │
│  │  │  │   30053      │  │              │  │              │       │  │   │
│  │  │  └──────────────┘  └──────────────┘  └──────────────┘       │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  Private Subnet 1b (10.19.2.0/24)                            │  │   │
│  │  │  ┌──────────────┐  ┌──────────────┐                          │  │   │
│  │  │  │ kafka-1 pod  │  │kraftctrl-1   │                          │  │   │
│  │  │  └──────────────┘  └──────────────┘                          │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  Private Subnet 1c (10.19.3.0/24)                            │  │   │
│  │  │  ┌──────────────┐  ┌──────────────┐                          │  │   │
│  │  │  │ kafka-2 pod  │  │kraftctrl-2   │                          │  │   │
│  │  │  └──────────────┘  └──────────────┘                          │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  VPC Endpoints (Interface Endpoints in each AZ)              │  │   │
│  │  │  - ECR API:  vpce-xxxxx.ecr.eu-west-1.vpce.amazonaws.com    │  │   │
│  │  │  - ECR DKR:  vpce-xxxxx.dkr.ecr.eu-west-1.vpce.amazonaws.com│  │   │
│  │  │  - EC2:      vpce-xxxxx.ec2.eu-west-1.vpce.amazonaws.com    │  │   │
│  │  │  - STS:      vpce-xxxxx.sts.eu-west-1.vpce.amazonaws.com    │  │   │
│  │  │  - S3:       Gateway Endpoint (FREE)                         │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## DNS Resolution Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          DNS Resolution Architecture                        │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────┐     │
│  │  Jumpbox (10.18.64.x)                                             │     │
│  │                                                                   │     │
│  │  Application                                                      │     │
│  │       │                                                           │     │
│  │       │ Query: kafka.confluent.svc.cluster.local                 │     │
│  │       ▼                                                           │     │
│  │  ┌─────────────────┐                                             │     │
│  │  │  systemd-       │                                             │     │
│  │  │  resolved       │                                             │     │
│  │  │  DNS=127.0.0.1  │                                             │     │
│  │  └────────┬────────┘                                             │     │
│  │           │                                                       │     │
│  │           ▼                                                       │     │
│  │  ┌─────────────────────────────────────────┐                     │     │
│  │  │  dnsmasq (127.0.0.1:53)                 │                     │     │
│  │  │                                         │                     │     │
│  │  │  Forwards *.cluster.local queries to:  │                     │     │
│  │  │  - 10.19.1.230:30053 (System Node 1)   │                     │     │
│  │  │  - 10.19.2.205:30053 (System Node 2)   │                     │     │
│  │  │                                         │                     │     │
│  │  │  Cache size: 1000                       │                     │     │
│  │  └────────┬────────────────────────────────┘                     │     │
│  └───────────┼───────────────────────────────────────────────────────┘     │
│              │                                                             │
│              │ VPC Peering                                                 │
│              ▼                                                             │
│  ┌───────────────────────────────────────────────────────────────────┐     │
│  │  EKS VPC - System Node (10.19.1.230)                             │     │
│  │                                                                   │     │
│  │  ┌─────────────────────────────────────────┐                     │     │
│  │  │  CoreDNS NodePort Service               │                     │     │
│  │  │  NodePort: 30053/UDP + 30053/TCP        │                     │     │
│  │  │         │                                │                     │     │
│  │  │         ▼                                │                     │     │
│  │  │  ┌───────────────────┐                  │                     │     │
│  │  │  │  CoreDNS Pod      │                  │                     │     │
│  │  │  │  10.19.1.244:53   │                  │                     │     │
│  │  │  │                   │                  │                     │     │
│  │  │  │  Resolves:        │                  │                     │     │
│  │  │  │  *.cluster.local  │                  │                     │     │
│  │  │  │  *.svc.cluster... │                  │                     │     │
│  │  │  └───────────────────┘                  │                     │     │
│  │  └─────────────────────────────────────────┘                     │     │
│  │                                                                   │     │
│  │  Returns: 10.19.1.104, 10.19.2.135, 10.19.3.83, ...             │     │
│  │  (Kafka broker IPs)                                              │     │
│  └───────────────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Storage Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Persistent Storage (EBS GP3)                        │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      KRaft Controllers (3 × 30Gi)                   │   │
│  │  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐   │   │
│  │  │  EBS Volume      │ │  EBS Volume      │ │  EBS Volume      │   │   │
│  │  │  30 GiB GP3      │ │  30 GiB GP3      │ │  30 GiB GP3      │   │   │
│  │  │  ──────────────  │ │  ──────────────  │ │  ──────────────  │   │   │
│  │  │  /var/lib/       │ │  /var/lib/       │ │  /var/lib/       │   │   │
│  │  │  kafka/metadata  │ │  kafka/metadata  │ │  kafka/metadata  │   │   │
│  │  │                  │ │                  │ │                  │   │   │
│  │  │  kraftctrl-0     │ │  kraftctrl-1     │ │  kraftctrl-2     │   │   │
│  │  │  AZ: eu-west-1a  │ │  AZ: eu-west-1b  │ │  AZ: eu-west-1c  │   │   │
│  │  └──────────────────┘ └──────────────────┘ └──────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      Kafka Brokers (4 × 50Gi)                       │   │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────┐  │   │
│  │  │ EBS Volume   │ │ EBS Volume   │ │ EBS Volume   │ │EBS Volume│  │   │
│  │  │ 50 GiB GP3   │ │ 50 GiB GP3   │ │ 50 GiB GP3   │ │50 GiB GP3│  │   │
│  │  │ ──────────── │ │ ──────────── │ │ ──────────── │ │──────────│  │   │
│  │  │ /var/lib/    │ │ /var/lib/    │ │ /var/lib/    │ │/var/lib/ │  │   │
│  │  │ kafka/data   │ │ kafka/data   │ │ kafka/data   │ │kafka/data│  │   │
│  │  │              │ │              │ │              │ │          │  │   │
│  │  │ - Topic data │ │ - Topic data │ │ - Topic data │ │- Topic...│  │   │
│  │  │ - Partitions │ │ - Partitions │ │ - Partitions │ │- Partiti.│  │   │
│  │  │ - Log        │ │ - Log        │ │ - Log        │ │- Log     │  │   │
│  │  │   segments   │ │   segments   │ │   segments   │ │  segments│  │   │
│  │  │              │ │              │ │              │ │          │  │   │
│  │  │ kafka-0      │ │ kafka-1      │ │ kafka-2      │ │ kafka-3  │  │   │
│  │  │AZ:eu-west-1a │ │AZ:eu-west-1b │ │AZ:eu-west-1c │ │AZ: 1a    │  │   │
│  │  └──────────────┘ └──────────────┘ └──────────────┘ └──────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Storage Class: gp3                                                         │
│  Performance: 3000 IOPS, 125 MB/s baseline                                 │
│  Total Storage: 290 GiB (90 GiB controllers + 200 GiB brokers)             │
│  Monthly Cost: ~$29/month ($0.10/GiB-month)                                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Security & TLS Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Security & Certificate Management                     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Certificate Authority (CA)                                         │   │
│  │  ┌───────────────────────────────────────────────────────────┐     │   │
│  │  │  Kubernetes Secret: ca-pair-sslcerts (namespace: confluent)│     │   │
│  │  │  - ca-cert.pem  (CA Certificate)                           │     │   │
│  │  │  - ca-key.pem   (CA Private Key)                           │     │   │
│  │  └────────────────────────┬──────────────────────────────────┘     │   │
│  └───────────────────────────┼─────────────────────────────────────────┘   │
│                              │                                             │
│                              │ Auto-generate & Sign                        │
│                              ▼                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Confluent Operator Auto-Generated Certificates                    │   │
│  │                                                                     │   │
│  │  ┌────────────────────┐  ┌────────────────────┐                    │   │
│  │  │  KRaft Controllers │  │  Kafka Brokers     │                    │   │
│  │  │                    │  │                    │                    │   │
│  │  │  Each pod gets:    │  │  Each pod gets:    │                    │   │
│  │  │  - Server cert     │  │  - Server cert     │                    │   │
│  │  │  - Private key     │  │  - Private key     │                    │   │
│  │  │  - Truststore      │  │  - Truststore      │                    │   │
│  │  │  - Keystore (JKS)  │  │  - Keystore (JKS)  │                    │   │
│  │  │                    │  │                    │                    │   │
│  │  │  Mounted at:       │  │  Mounted at:       │                    │   │
│  │  │  /mnt/sslcerts/    │  │  /mnt/sslcerts/    │                    │   │
│  │  └────────────────────┘  └────────────────────┘                    │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  TLS Configuration                                                  │   │
│  │                                                                     │   │
│  │  Protocol:             TLS 1.3 ONLY                                │   │
│  │  Client Auth:          Required (mTLS)                             │   │
│  │  Endpoint Validation:  HTTPS                                       │   │
│  │                                                                     │   │
│  │  Kafka Listeners:                                                  │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  internal:9071 (mTLS)                                        │  │   │
│  │  │  - Broker-to-broker replication                             │  │   │
│  │  │  - Client connections                                        │  │   │
│  │  │  - Inter-controller communication                           │  │   │
│  │  │                                                              │  │   │
│  │  │  controller:9073 (TLS)                                       │  │   │
│  │  │  - KRaft metadata replication                               │  │   │
│  │  │  - Controller quorum communication                          │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  Principal Mapping:                                                │   │
│  │  CN=(name),OU=Engineering,O=Confluent,L=MountainView,ST=CA,C=US   │   │
│  │  ──────────────────────────────────────────────────────────────▶   │   │
│  │  Kafka Principal: (name)                                           │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Karpenter Autoscaling Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Karpenter Dynamic Node Provisioning                    │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Karpenter Operator (namespace: karpenter)                          │   │
│  │                                                                     │   │
│  │  Monitors:                                                          │   │
│  │  - Pending pods                                                     │   │
│  │  │  - Node requirements (taints, tolerations, affinity)            │   │
│  │  - Underutilized nodes                                              │   │
│  │  - Consolidation opportunities                                      │   │
│  └──────────────────────────┬──────────────────────────────────────────┘   │
│                             │                                              │
│                             │ Provision/Terminate                          │
│                             ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  NodePools (3)                                                      │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  system-nodes (On-Demand, x86_64)                           │  │   │
│  │  │  - Instance types: t3.medium, t3.large                       │  │   │
│  │  │  - Limits: 3 nodes max, 12 vCPU                              │  │   │
│  │  │  - Purpose: CoreDNS, operators, system workloads             │  │   │
│  │  │  - Taints: None (unscheduled workloads)                      │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  kafka-nodes (Spot, ARM64)                                   │  │   │
│  │  │  - Instance types: c6g.xlarge, c6g.2xlarge, c7g.xlarge       │  │   │
│  │  │  - Limits: 20 nodes max, 160 vCPU                            │  │   │
│  │  │  - Purpose: Kafka brokers, KRaft controllers                 │  │   │
│  │  │  - Taints: arch=arm64:NoSchedule                             │  │   │
│  │  │  - Consolidation: Enabled (bin-packing)                      │  │   │
│  │  │  - Interruption: Handled gracefully                          │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌──────────────────────────────────────────────────────────────┐  │   │
│  │  │  general-nodes (Spot, ARM64)                                 │  │   │
│  │  │  - Instance types: t4g.medium, t4g.large, c6g.large          │  │   │
│  │  │  - Limits: 10 nodes max, 40 vCPU                             │  │   │
│  │  │  - Purpose: General workloads, testing                       │  │   │
│  │  │  - Taints: None                                              │  │   │
│  │  └──────────────────────────────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  Provisioning Flow:                                                         │
│  1. Pod created with toleration: arch=arm64                                │
│  2. No node available with matching taint                                  │
│  3. Karpenter creates NodeClaim for kafka-nodes pool                       │
│  4. EC2 Spot instance launched (c6g.xlarge)                                │
│  5. Node joins cluster, pod scheduled                                      │
│  6. After 30min idle, node consolidated/terminated                         │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Cost Breakdown

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Monthly Cost Breakdown (~$248)                      │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Fixed Costs (Base Infrastructure)                                  │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  EKS Control Plane                     │  $73.00/month        │  │   │
│  │  │  - Kubernetes API server               │  (Fixed cost)        │  │   │
│  │  │  - etcd cluster                        │                      │  │   │
│  │  │  - Controller managers                 │                      │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  VPC Endpoints (4 Interface + 1 GW)    │  $90.00/month        │  │   │
│  │  │  - ECR API:    $0.01/hr × 3 AZ × 730hr │  $21.90              │  │   │
│  │  │  - ECR DKR:    $0.01/hr × 3 AZ × 730hr │  $21.90              │  │   │
│  │  │  - EC2:        $0.01/hr × 3 AZ × 730hr │  $21.90              │  │   │
│  │  │  - STS:        $0.01/hr × 3 AZ × 730hr │  $21.90              │  │   │
│  │  │  - S3 Gateway: FREE                    │  $0.00               │  │   │
│  │  │  - Data processing: ~$2/month          │  $2.40               │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Variable Costs (Current: Small Kafka Cluster)                      │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  System Node (1× t3.large on-demand)   │  $63.00/month        │  │   │
│  │  │  - vCPU: 2, RAM: 8GB                   │  $0.0832/hr          │  │   │
│  │  │  - Runs: CoreDNS, operators            │  × 730 hrs           │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  Kafka Nodes (Spot ARM64)              │  $60-80/month        │  │   │
│  │  │  - 3× c6g.xlarge (controllers)         │  ~$25/month          │  │   │
│  │  │    $0.0544/hr spot × 3 × 50% uptime    │                      │  │   │
│  │  │  - 4× c6g.xlarge (brokers)             │  ~$40/month          │  │   │
│  │  │    $0.0544/hr spot × 4 × 60% uptime    │                      │  │   │
│  │  │  Note: Spot pricing ~65% discount      │                      │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  Storage (EBS GP3)                     │  $29.00/month        │  │   │
│  │  │  - 3× 30Gi (controllers): 90Gi         │  $9.00               │  │   │
│  │  │  - 4× 50Gi (brokers): 200Gi            │  $20.00              │  │   │
│  │  │  - Rate: $0.10/GiB-month               │                      │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  CloudWatch                            │  $14.00/month        │  │   │
│  │  │  - Logs ingestion                      │  ~$8/month           │  │   │
│  │  │  - Metrics                             │  ~$6/month           │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  │                                                                     │   │
│  │  ┌────────────────────────────────────────┬──────────────────────┐  │   │
│  │  │  Other (KMS, Data Transfer, IPs)       │  $8.00/month         │  │   │
│  │  └────────────────────────────────────────┴──────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │  Total Monthly Cost Summary                                         │   │
│  │                                                                     │   │
│  │  Base Infrastructure (no Kafka):        ~$248/month                │   │
│  │  With Small Kafka (3+4 nodes):          ~$330/month                │   │
│  │  With Large Kafka (5+12 nodes):         ~$511/month                │   │
│  │                                                                     │   │
│  │  Current: Base only (Kafka stopped)     ~$248/month                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Component Versions

| Component | Version | Notes |
|-----------|---------|-------|
| **Kubernetes** | 1.35 | EKS managed |
| **Confluent Platform** | 8.2.1 | cp-server image |
| **Confluent Operator** | 3.2.2 (Helm 0.1514.40) | CFK |
| **Karpenter** | 1.12.1 | Node autoscaler |
| **CoreDNS** | 1.14.2-eksbuild.4 | EKS addon |
| **vpc-cni** | 1.21.2-eksbuild.2 | EKS addon |
| **kube-proxy** | 1.35.3-eksbuild.8 | EKS addon |
| **aws-ebs-csi-driver** | 1.60.0-eksbuild.1 | EKS addon |
| **Amazon Linux** | 2023 | Node OS |

---

## Key Features

### High Availability
- **Multi-AZ Deployment**: Resources spread across 3 availability zones
- **Pod Anti-Affinity**: Ensures replicas on different nodes/zones
- **Rack Awareness**: Kafka rack assignment per AZ
- **Replication Factor**: 3 (min ISR: 2)

### Security
- **mTLS**: Mutual TLS for all inter-broker communication
- **TLS 1.3**: Latest TLS protocol only
- **Auto-Generated Certs**: Confluent operator manages certificates
- **Private Subnets**: No direct internet access
- **VPC Endpoints**: Private AWS service access

### Cost Optimization
- **Spot Instances**: 65% discount on Kafka nodes
- **ARM64 (Graviton)**: 35% cheaper than x86
- **Auto-Scaling**: Karpenter provisions nodes on-demand
- **Consolidation**: Karpenter bin-packing and node consolidation
- **GP3 Storage**: Cheaper than GP2, better IOPS

### Observability
- **Metric Reporter**: Built-in Kafka metrics
- **CloudWatch**: Logs and metrics
- **Jolokia**: JMX metrics via HTTP

---

## Deployment Options

### 1. Base Infrastructure Only (~$248/month)
- EKS cluster + VPC + 1 system node
- No Kafka cluster running
- **Current configuration**

### 2. Small Kafka Cluster (~$330/month)
- 3 KRaft controllers + 4 Kafka brokers
- Suitable for development/testing
- **Cost-optimized option**

### 3. Large Kafka Cluster (~$511/month)
- 5 KRaft controllers + 12 Kafka brokers
- Production-grade HA setup
- **Full redundancy**

---

## Related Documentation

- [Main README](README.md) - Getting started
- [Kafka README](kafka/README.md) - Kafka deployment guide
- [Cost Analysis](COST-ANALYSIS.md) - Detailed cost breakdown
- [Terraform README](tf/README.md) - Infrastructure as code
