# 🚀 EKS, KARPENTER, AND CONFLUENT (KRaft) TERRAFORM DEPLOYMENT

This document outlines the final, corrected Terraform configuration for deploying a production-ready AWS EKS cluster with dynamic scaling (Karpenter) and a highly available Confluent Kafka cluster using KRaft mode.

The purpose was to replicate what we observe in our on-prem customers.

## 🎯 Current Deployment Status (2026-05-23)

✅ **FULLY OPERATIONAL**

| Component | Version | Status | Replicas |
|-----------|---------|--------|----------|
| EKS Cluster | 1.35 | ✅ Running | - |
| Confluent Operator | 3.2.2 (0.1514.40) | ✅ Running | 2 |
| Confluent Platform | 8.2.1 | ✅ Running | - |
| KRaft Controllers | 8.2.1 | ✅ Running | 5/5 |
| Kafka Brokers | 8.2.1 | ✅ Running | 12/12 |
| Karpenter | 1.12.1 | ✅ Running | Spot ARM64 |

**Security**: mTLS with auto-generated certificates, TLS 1.3 only

📖 **Kafka Deployment Guide**: [kafka/README.md](kafka/README.md)

---

## Infrastructure Overview

This version resolves multiple complex issues related to:
- VPC Peering
- CNI permissions (IRSA)
- Karpenter Operator deployment
- Karpenter NodeClass installation
- Confluent Operator compliance
- mTLS certificate management

**Kubernetes Version**: EKS 1.35 (upgraded from 1.33)
- Upgrade timeline: [tf/STAGED-UPGRADE.md](tf/STAGED-UPGRADE.md)
- Next review: March 2027 (end of standard support)

---

## Table of Contents

1.  [Prerequisites](#1-prerequisites)
2.  [Final Terraform Configuration (`main.tf`)](#2-final-terraform-configuration-maintf)
3.  [Configuration Breakdown and Key Fixes](#3-configuration-breakdown-and-key-fixes)
4.  [Troubleshooting Retrospective](#4-troubleshooting-retrospective)

---

## Prerequisites

This is Mandatory.
Before running this configuration, ensure you have:

* **AWS CLI and `kubectl`** installed and configured locally

* An existing ssh key configured in AWS 
* Choose a free /16 available on in your AWS preferred region. We will split it in 2 (not equally):
- /18 for the EKS cluster (containing brokers, controllers, etc...)
- the rest of the range for the jumpbox vpc (only 1 machine)
* You need to be able to create 2 additional VPCs, by default AWS accounts to 5 VPCs but you can request a quota increase on [here](https://eu-west-1.console.aws.amazon.com/servicequotas/home/services/vpc/quotas)



## EDIT your own variables.tf

This is Mandatory.

## Final Terraform Configuration (`main.tf`)

3 key Terraform files:
* [main.tf](tf/main.tf])
Will provision the vpc for the eks cluster, set up permissions, install necessary k8s operators
karpenter, EKS (Kubernetes), eks cni addon, csi storage driver, vpc endpoints, iam permissions, security groups... etc
This VPC will not have be reachable through public internet access
We will need to create a vpc peering and use endpoints to reach AWS services such as S3, ECR, sts, ec2.

* [networking.tf](tf/networking.tf])
Will connect the two VPCs and add the necessary routes

* [jumpbox.tf](tf/jumpbox.tf])
Will create a jumpbox in its own vpc with internet access.

## Update the kubeconfig

```
aws eks --region eu-west-1 update-kubeconfig --name your-cluster
```


kubectl get pods -A will return all the pods from all namespaces

## Connect via ssh to the jump server

Copy [install_binaries](tf/scripts/install_binaries.sh) on the remote machine and execute it.
It will install both java and Confluent Platform binaries



Add the nameserver matching your dns endpoint

```
kubectl get endpoints -n kube-system kube-dns
NAME       ENDPOINTS                                                  AGE
kube-dns   10.19.1.244:53,10.19.2.181:53,10.19.1.244:53 + 3 more...   161m
```


Connect on the jumpbox and change the dns settings

Edit /etc/systemd/resolved.conf 
restart dns : sudo systemctl restart systemd-resolved

```
DNS=10.19.1.244
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
```

It will eventually modify /etc/resolv.conf as below:
```
search confluent.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.19.1.244
```

```
 resolvectl status
Global
       Protocols: -LLMNR -mDNS -DNSOverTLS DNSSEC=no/unsupported
resolv.conf mode: uplink
      DNS Servers 10.19.1.244
       DNS Domain cluster.local confluent.svc.cluster.local svc.cluster.local
```

You can test the setup with the below with:
```
kafka-broker-api-versions --bootstrap-server kafka.confluent.svc.cluster.local:9092 | grep rack | awk '{ print $5 " " $1}' | sort
eu-west-1a kafka-0.kafka.confluent.svc.cluster.local:9092
eu-west-1a kafka-10.kafka.confluent.svc.cluster.local:9092
eu-west-1a kafka-3.kafka.confluent.svc.cluster.local:9092
eu-west-1a kafka-9.kafka.confluent.svc.cluster.local:9092
eu-west-1b kafka-1.kafka.confluent.svc.cluster.local:9092
eu-west-1b kafka-5.kafka.confluent.svc.cluster.local:9092
eu-west-1b kafka-7.kafka.confluent.svc.cluster.local:9092
eu-west-1b kafka-8.kafka.confluent.svc.cluster.local:9092
eu-west-1c kafka-11.kafka.confluent.svc.cluster.local:9092
eu-west-1c kafka-2.kafka.confluent.svc.cluster.local:9092
eu-west-1c kafka-4.kafka.confluent.svc.cluster.local:9092
eu-west-1c kafka-6.kafka.confluent.svc.cluster.local:9092

```

```
2 on az1
kraft-controller-2-internal   10.19.1.72:9074,10.19.1.72:7777,10.19.1.72:7778 + 2 more...      161m
kraft-controller-3-internal   10.19.1.110:9074,10.19.1.110:7777,10.19.1.110:7778 + 2 more...   161m

2 on az2
kraft-controller-0-internal   10.19.2.136:9074,10.19.2.136:7777,10.19.2.136:7778 + 2 more...   161m
kraft-controller-4-internal   10.19.2.202:9074,10.19.2.202:7777,10.19.2.202:7778 + 2 more...   161m

1 on az3
kraft-controller-1-internal   10.19.3.62:9074,10.19.3.62:7777,10.19.3.62:7778 + 2 more...      161m

```

## Topic Tests

 Create a file for the test-multi-az.json
```
cat > placement-multi-az.json << EOF
{
    "version": 1,
    "replicas": [
        {
            "count": 1,
            "constraints": {
                "rack": "eu-west-1a"
            }
        },
        {
            "count": 1,
            "constraints": {
                "rack": "eu-west-1b"
            }
	},
        {
            "count": 1,
            "constraints": {
                "rack": "eu-west-1c"
            }
        }
    ]
}

EOF
```


```
export BS=kafka.confluent.svc.cluster.local:9092
 kafka-topics  --create \
	--bootstrap-server $BS \
	--topic test-multi-az \
	--partitions 6 \
	--replica-placement placement-multi-az.json \
	--config min.insync.replicas=2
kafka-topics  --create    --bootstrap-server $BS  --topic test-multi-az   --partitions 6  --replica-placement placement-multi-az.json     --config min.insync.replicas=2
kafka-producer-perf-test --topic test-multi-az --record-size 5 --throughput -1 --num-records 100000  --producer-props bootstrap.servers=$BS acks=all
kafka-topics -describe -topic test-multi-az  -bootstrap-server $BS


```



## Troubleshooting commands:


* Karpenter pod scheduling: that step should be quick.
```
kubectl describe pod  -n karpenter -l app.kubernetes.io/name=karpenter
```



* Kafka brokers are unreachable, even when using k8s endpoints ?
Maybe the route is missing between the jumpbox vpc and the eks cluster vpc.

```
Issue with the route from the jump box, create it manually with

aws ec2 create-route \
    --route-table-id rtb-0cf564d9f304c5104 \
    --destination-cidr-block 10.19.0.0/18 \
    --vpc-peering-connection-id pcx-02ec55dd8db80bb1b --region eu-west-1



    aws ec2 create-route \
    --route-table-id rtb-0cf564d9f304c5104 \
    --destination-cidr-block 10.19.0.0/18 \
    --vpc-peering-connection-id pcx-02ec55dd8db80bb1b --region eu-west-1
```


* Painful one, node groups takes 5-15 min to be created/deleted.



Delete the old one
```
aws eks delete-nodegroup \
  --cluster-name demo-cluster \
  --nodegroup-name demo-system-20251215182701639900000001  \
  --region eu-west-1
```

feel free to rename
```
eks_managed_node_groups = {
  system_nodes = {
    #change v2 suffix if needed
    name         = "${var.project_name}-system" 
    min_size     = 1
    max_size     = 3
    desired_size = 1
```

Then,
```
# Refresh Terraform state to match AWS reality
terraform refresh

# Then plan and apply
terraform plan
terraform apply
```



```

aws eks create-nodegroup \
  --cluster-name demo-cluster \
  --nodegroup-name simple-bootstrap \
  --node-role arn:aws:iam::YOUR_AWS_ACCOUNT_ID:role/demo-system-v4-eks-node-group-20251215211632535100000001 \
  --subnets subnet-0c994f75695f56a1a \
  --instance-types t3.large \
  --ami-type AL2_x86_64 \
  --scaling-config minSize=1,maxSize=1,desiredSize=1 \
  --region eu-west-1

  ```