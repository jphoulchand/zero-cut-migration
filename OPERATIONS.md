# Day 2 Operations Guide

This guide covers common operational tasks for managing the Confluent Kafka deployment on AWS EKS.

## Table of Contents

- [Starting and Stopping](#starting-and-stopping)
- [Scaling](#scaling)
- [Monitoring](#monitoring)
- [Backup and Recovery](#backup-and-recovery)
- [Troubleshooting](#troubleshooting)
- [Cost Optimization](#cost-optimization)

---

## Starting and Stopping

### Pause Kafka Cluster (Scale to 0)

Save costs during non-working hours or testing periods:

```bash
# Scale down all Kafka components
kubectl scale kafka kafka --replicas=0 -n confluent
kubectl scale kraftcontroller kraftcontroller --replicas=0 -n confluent

# If Schema Registry and Connect are deployed
kubectl scale schemaregistry schemaregistry --replicas=0 -n confluent 2>/dev/null || true
kubectl scale connect connect --replicas=0 -n confluent 2>/dev/null || true

# Watch pods terminate
kubectl get pods -n confluent -w
```

**What happens:**
- All Kafka pods terminate gracefully
- Karpenter detects unused capacity and terminates spot instances (~5-10 min)
- EBS volumes persist (data is safe)
- Daily cost: ~$193/month (from ~$511/month) = **~$10/day savings**

**Data Safety:** ✅ EBS volumes are retained, data is NOT lost

### Resume Kafka Cluster (Scale Up)

Restore the cluster to full capacity:

```bash
# Scale up to original replica counts
kubectl scale kafka kafka --replicas=12 -n confluent
kubectl scale kraftcontroller kraftcontroller --replicas=5 -n confluent

# If Schema Registry and Connect are deployed
kubectl scale schemaregistry schemaregistry --replicas=2 -n confluent 2>/dev/null || true
kubectl scale connect connect --replicas=2 -n confluent 2>/dev/null || true

# Watch pods start (Karpenter provisions instances automatically)
kubectl get pods -n confluent -w
```

**Recovery time:** ~5-10 minutes
- Karpenter provisions new spot instances (~2-3 min)
- Pods initialize and attach EBS volumes (~3-5 min)
- Brokers rejoin cluster and sync (~2-3 min)

### Automated Daily Shutdown (Optional)

For testing environments, automate shutdown with CronJobs:

```bash
# Scale down at 6 PM weekdays
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-scale-down
  namespace: confluent
spec:
  schedule: "0 18 * * 1-5"  # 6 PM Mon-Fri
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: kafka-scaler
          restartPolicy: Never
          containers:
          - name: scaler
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - -c
            - |
              kubectl scale kafka kafka --replicas=0 -n confluent
              kubectl scale kraftcontroller kraftcontroller --replicas=0 -n confluent
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-scale-up
  namespace: confluent
spec:
  schedule: "0 8 * * 1-5"  # 8 AM Mon-Fri
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: kafka-scaler
          restartPolicy: Never
          containers:
          - name: scaler
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - -c
            - |
              kubectl scale kafka kafka --replicas=12 -n confluent
              kubectl scale kraftcontroller kraftcontroller --replicas=5 -n confluent
EOF
```

**Note:** Requires RBAC ServiceAccount with scale permissions.

---

## Scaling

### Scale Kafka Brokers

Increase or decrease broker count:

```bash
# Scale to 18 brokers (from 12)
kubectl scale kafka kafka --replicas=18 -n confluent

# Or edit the kafka-core.yaml and apply
kubectl edit kafka kafka -n confluent
# Change spec.replicas to desired count
```

**Considerations:**
- Minimum 3 brokers for replication factor 3
- Karpenter will provision additional instances automatically
- Rebalance partitions after scaling up (see below)

### Rebalance Partitions After Scaling

When adding brokers, rebalance partitions for even distribution:

```bash
# Generate partition reassignment plan
kubectl exec -n confluent kafka-0 -- kafka-reassign-partitions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --broker-list "0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17" \
  --topics-to-move-json-file /tmp/topics.json \
  --generate \
  --command-config /etc/kafka/client.properties

# Execute reassignment
kubectl exec -n confluent kafka-0 -- kafka-reassign-partitions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --reassignment-json-file /tmp/reassignment.json \
  --execute \
  --command-config /etc/kafka/client.properties

# Monitor progress
kubectl exec -n confluent kafka-0 -- kafka-reassign-partitions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --reassignment-json-file /tmp/reassignment.json \
  --verify \
  --command-config /etc/kafka/client.properties
```

### Scale KRaft Controllers

**Warning:** KRaft controllers should always be an odd number (3, 5, 7) for quorum.

```bash
# Scale to 7 controllers (from 5)
kubectl scale kraftcontroller kraftcontroller --replicas=7 -n confluent
```

### Scale Schema Registry / Connect

```bash
# Schema Registry (increase to 3 replicas)
kubectl scale schemaregistry schemaregistry --replicas=3 -n confluent

# Connect (increase to 4 workers)
kubectl scale connect connect --replicas=4 -n confluent
```

---

## Monitoring

### Check Cluster Health

```bash
# All pods status
kubectl get pods -n confluent

# Kafka broker status
kubectl exec -n confluent kafka-0 -- kafka-broker-api-versions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --command-config /etc/kafka/client.properties

# Under-replicated partitions (should be 0)
kubectl exec -n confluent kafka-0 -- kafka-topics \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --describe \
  --under-replicated-partitions \
  --command-config /etc/kafka/client.properties

# Consumer group lag
kubectl exec -n confluent kafka-0 -- kafka-consumer-groups \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --describe \
  --all-groups \
  --command-config /etc/kafka/client.properties
```

### View Logs

```bash
# Tail Kafka broker logs
kubectl logs -n confluent kafka-0 -f

# Check for errors in last 100 lines
kubectl logs -n confluent kafka-0 --tail=100 | grep -i error

# KRaft controller logs
kubectl logs -n confluent kraftcontroller-0 -f

# All broker logs
kubectl logs -n confluent -l app=kafka --tail=50
```

### Check JMX Metrics

```bash
# Port-forward to broker JMX metrics
kubectl port-forward -n confluent kafka-0 9091:9091

# In another terminal, check metrics
curl http://localhost:9091/metrics | grep kafka_server_brokertopicmetrics
```

---

## Backup and Recovery

### Manual EBS Snapshot (Broker Data)

```bash
# Get EBS volume IDs for Kafka brokers
kubectl get pvc -n confluent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumeName}{"\n"}{end}'

# Create snapshot via AWS CLI
aws ec2 create-snapshot \
  --volume-id vol-xxxxxxxxx \
  --description "kafka-broker-0-backup-$(date +%Y%m%d)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=kafka-broker-0-backup}]'
```

### Export Topic Data (Kafka Connect S3 Sink)

For logical backups, use Kafka Connect S3 Sink Connector:

```bash
# Deploy S3 sink connector (example)
kubectl apply -f - <<EOF
apiVersion: platform.confluent.io/v1beta1
kind: Connector
metadata:
  name: s3-sink-backup
  namespace: confluent
spec:
  class: "io.confluent.connect.s3.S3SinkConnector"
  taskMax: 3
  connectClusterRef:
    name: connect
  configs:
    topics: "topic1,topic2,topic3"
    s3.bucket.name: "your-kafka-backup-bucket"
    s3.region: "eu-west-1"
    flush.size: "1000"
    storage.class: "io.confluent.connect.s3.storage.S3Storage"
    format.class: "io.confluent.connect.s3.format.json.JsonFormat"
EOF
```

---

## Troubleshooting

### Pod Stuck in Pending

```bash
# Check pod events
kubectl describe pod kafka-0 -n confluent

# Common causes:
# 1. No nodes available (check Karpenter)
kubectl get nodes -o wide

# 2. EBS volume attachment issues
kubectl get pvc -n confluent

# 3. Resource constraints
kubectl top nodes
```

### Broker Not Joining Cluster

```bash
# Check broker logs for errors
kubectl logs -n confluent kafka-0 --tail=200 | grep -i error

# Verify network connectivity
kubectl exec -n confluent kafka-0 -- ping kafka-1.kafka.confluent.svc.cluster.local

# Check KRaft controller connectivity
kubectl exec -n confluent kafka-0 -- \
  nc -zv kraftcontroller-0.kraftcontroller.confluent.svc.cluster.local 9093
```

### High Consumer Lag

```bash
# Identify lagging consumer groups
kubectl exec -n confluent kafka-0 -- kafka-consumer-groups \
  --bootstrap-server kafka.confluent.svc.cluster.local:9071 \
  --describe \
  --all-groups \
  --command-config /etc/kafka/client.properties | grep -E "LAG|CONSUMER-ID"

# Scale up consumer group instances or optimize consumer code
```

---

## Cost Optimization

### Current Monthly Cost: ~$511

| Component | Cost | Optimization |
|-----------|------|--------------|
| EKS Control Plane | $73 | Fixed |
| System Nodes (2x t3.large) | $120 | Consider spot |
| Kafka Brokers (12x spot) | $85 | Scale down to 6 |
| KRaft Controllers (5x spot) | $35 | Keep as is |
| VPC Endpoints | $92 | Keep for security |
| Other (EBS, IPs) | $114 | Reduce broker storage |
| **Total** | **$511** | |

### Cost-Saving Strategies

1. **Scale down during off-hours** (see above)
   - Savings: ~$318/month (~62%)

2. **Reduce broker count** (if workload allows)
   ```bash
   kubectl scale kafka kafka --replicas=6 -n confluent
   ```
   - Savings: ~$47/month (~9%)

3. **Reduce broker storage** (if usage < 30GB)
   ```bash
   # Edit kafka-core.yaml
   spec:
     dataVolumeCapacity: 30Gi  # from 50Gi
   
   kubectl apply -f kafka-core.yaml
   ```
   - Savings: ~$8/month (~2%)

4. **Use Savings Plans / Reserved Instances** for system nodes
   - Savings: ~$40/month (~8%) if running 24/7 for 1 year

### Cost Monitoring

```bash
# Check current AWS costs
aws ce get-cost-and-usage \
  --time-period Start=2026-05-01,End=2026-05-23 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE
```

---

## Complete Cleanup (Destroy Everything)

When finished with the deployment:

```bash
# 1. Delete Kafka resources
kubectl delete -f kafka/kafka-core.yaml
kubectl delete -f kafka/kafka-auxiliary.yaml 2>/dev/null || true
kubectl delete -f kafka/kafka-jmx-config.yaml
kubectl delete -f kafka/kafka-rbac.yaml

# 2. Delete monitoring (if deployed)
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring

# 3. Delete Confluent operator
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent

# 4. Destroy AWS infrastructure
cd tf
terraform destroy -auto-approve
```

**What gets deleted:**
- ✅ EKS cluster and all worker nodes
- ✅ VPCs, subnets, security groups
- ✅ EBS volumes (**Kafka data will be lost**)
- ✅ VPC endpoints
- ✅ Jumpbox and Elastic IP
- ✅ All Terraform-managed resources

**Total time:** ~15-20 minutes

---

## Quick Reference Commands

```bash
# Status
kubectl get pods -n confluent
kubectl get kafka -n confluent

# Scale down (pause)
kubectl scale kafka kafka --replicas=0 -n confluent
kubectl scale kraftcontroller kraftcontroller --replicas=0 -n confluent

# Scale up (resume)
kubectl scale kafka kafka --replicas=12 -n confluent
kubectl scale kraftcontroller kraftcontroller --replicas=5 -n confluent

# Logs
kubectl logs -n confluent kafka-0 -f

# Metrics
kubectl port-forward -n confluent kafka-0 9091:9091

# Cleanup
kubectl delete -f kafka/kafka-core.yaml
cd tf && terraform destroy
```
