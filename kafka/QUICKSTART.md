# Kafka Cluster - Quick Start Guide

Fast deployment reference for the Confluent Kafka cluster on EKS.

## Prerequisites Checklist

- [ ] EKS cluster running (Kubernetes 1.35)
- [ ] Confluent operator deployed (v3.2.2 / 0.1514.40)
- [ ] Karpenter configured with ARM64 spot instances
- [ ] `kubectl` configured to access the cluster

## 5-Minute Deployment

### 1. Create CA Secret (1 min)

```bash
cd kafka/certs
./generate-kafka-certs.sh

kubectl create secret tls ca-pair-sslcerts \
  --cert=generated-certs/ca/ca-cert.pem \
  --key=generated-certs/ca/ca-key.pem \
  -n confluent
```

### 2. Deploy RBAC (30 sec)

```bash
kubectl apply -f kafka-rbac.yaml
```

### 3. Deploy Kafka Core (3-5 min)

```bash
kubectl apply -f kafka-core.yaml
```

**Monitor deployment**:

```bash
kubectl get pods -n confluent -w
```

Wait for all pods `Running` and `1/1 READY`.

### 4. Verify (1 min)

```bash
# Check cluster status
kubectl get kafka -n confluent

# Expected: 12/12 RUNNING
# NAME    REPLICAS   READY   STATUS    AGE
# kafka   12         12      RUNNING   5m

# Check controllers
kubectl get kraftcontroller -n confluent

# Expected: 5/5 RUNNING
```

### 5. Deploy Schema Registry + Connect (Optional)

```bash
kubectl apply -f kafka-auxiliary.yaml
```

## Quick Commands

### Status Checks

```bash
# All Kafka pods
kubectl get pods -n confluent -l platform.confluent.io/type=kafka

# All components
kubectl get kafka,kraftcontroller,schemaregistry,connect -n confluent

# Operator logs
kubectl logs -n confluent -l app=confluent-operator --tail=50
```

### Get Broker Endpoints

```bash
kubectl get kafka kafka -n confluent \
  -o jsonpath='{.status.listeners.internal.client}' | fold -w 80
```

### Get Auto-Generated Certificates

```bash
# List all TLS secrets
kubectl get secrets -n confluent -l 'platform.confluent.io/type'

# View certificate details
kubectl get secret <secret-name> -n confluent -o yaml
```

### DNS Testing (from jumpbox)

```bash
# Resolve Kafka service
dig kafka.confluent.svc.cluster.local +short

# Resolve specific broker
dig kafka-0.kafka.confluent.svc.cluster.local +short
```

### Test Kafka Connection

```bash
# From a client pod
kubectl run -it --rm kafka-test \
  --image=confluentinc/cp-kafka:8.2.1 \
  --restart=Never \
  --namespace=confluent -- bash

# Inside pod - list topics
kafka-topics --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --list \
  --command-config /path/to/client.properties
```

## Troubleshooting Quick Fixes

### Pods Stuck in Pending

```bash
# Check Karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=20

# Check events
kubectl get events -n confluent --sort-by='.lastTimestamp' | tail -20

# Check node capacity
kubectl get nodes -o wide
```

### Certificate Errors

```bash
# Verify CA secret
kubectl get secret ca-pair-sslcerts -n confluent

# Recreate if missing
kubectl create secret tls ca-pair-sslcerts \
  --cert=certs/generated-certs/ca/ca-cert.pem \
  --key=certs/generated-certs/ca/ca-key.pem \
  -n confluent

# Force recreate pods
kubectl delete pods -n confluent -l app=kafka
```

### Clean Restart

```bash
# Delete Kafka cluster (preserves data)
kubectl delete kafka kafka -n confluent
kubectl delete kraftcontroller kraftcontroller -n confluent

# Wait for cleanup (~30 sec)
sleep 30

# Redeploy
kubectl apply -f kafka-core.yaml
```

### Full Reset (⚠️ DELETES ALL DATA)

```bash
# Delete everything
kubectl delete kafka --all -n confluent
kubectl delete kraftcontroller --all -n confluent
kubectl delete pvc --all -n confluent
kubectl delete secret ca-pair-sslcerts -n confluent

# Redeploy from scratch
# (follow 5-minute deployment steps above)
```

## Performance Tuning

### Check Resource Usage

```bash
# CPU/Memory usage
kubectl top pods -n confluent

# Storage usage
kubectl get pvc -n confluent

# Node capacity
kubectl describe nodes | grep -A 5 "Allocated resources"
```

### Scale Brokers

```bash
# Edit kafka-core.yaml
# Change: spec.replicas: 16

kubectl apply -f kafka-core.yaml
```

### Increase Storage

```bash
# Edit kafka-core.yaml
# Change: dataVolumeCapacity: 100Gi

# Note: Cannot shrink, only expand
kubectl apply -f kafka-core.yaml
```

## Configuration Files

| File | Purpose | When to Apply |
|------|---------|---------------|
| `kafka-rbac.yaml` | RBAC permissions | First (before kafka-core) |
| `kafka-core.yaml` | KRaft + Kafka brokers | Second |
| `kafka-auxiliary.yaml` | Schema Registry + Connect | After core verified |

## Default Ports

| Service | Port | Protocol | Usage |
|---------|------|----------|-------|
| Kafka Internal | 9071 | SSL (mTLS) | Inter-broker + clients |
| Kafka External | 9092 | SSL (mTLS) | External clients |
| Kafka Controller | 9074 | Plaintext | KRaft communication |
| Kafka Replication | 9072 | SSL (mTLS) | Broker replication |
| Schema Registry | 8081 | HTTPS | Schema management |
| Kafka Rest | 8090 | HTTP | REST API |

## Key Features Enabled

✅ KRaft mode (no ZooKeeper)
✅ mTLS authentication
✅ Auto-generated certificates
✅ TLS 1.3 encryption
✅ Multi-AZ deployment
✅ ARM64 spot instances
✅ GP3 storage
✅ Pod anti-affinity
✅ Rack awareness
✅ Replication factor: 3
✅ Min in-sync replicas: 2

## Next Steps

- [x] Deploy Kafka core
- [ ] Deploy Schema Registry + Connect
- [ ] Configure topics with proper replication
- [ ] Set up monitoring (Prometheus/Grafana)
- [ ] Configure external access (if needed)
- [ ] Set up backup/disaster recovery
- [ ] Configure ACLs (if using RBAC)

## Documentation

- Full Guide: [README.md](README.md)
- Upgrade Path: [../tf/STAGED-UPGRADE.md](../tf/STAGED-UPGRADE.md)
- Terraform Config: [../tf/main.tf](../tf/main.tf)
- Architecture: [../main.md](../main.md)
