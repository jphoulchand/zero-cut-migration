# AWS Cost Analysis - Current State (Kafka Deleted)

**Date:** May 23, 2026  
**Status:** Kafka brokers and KRaft controllers deleted for cost savings

---

## Current Monthly Cost Projection

| Service | Monthly Cost | Notes |
|---------|--------------|-------|
| **EKS Control Plane** | $73.00 | 1 cluster @ $0.10/hour |
| **System Nodes** | $63.00 | 1× t3.large on-demand (24/7) |
| **VPC Endpoints** | $91.83 | 4 interface endpoints × 3 AZs |
| **CloudWatch** | $14.00 | Logs and metrics |
| **System EBS Volumes** | $1.60 | 1× 20GB @ $0.08/GB |
| **Elastic IPs** | $7.20 | ~2 IPs @ $3.60/month |
| **KMS** | $0.94 | Encryption keys |
| **Data Transfer** | $5.00 | Misc egress |
| **TOTAL** | **~$256** | Base infrastructure only |

---

## Kafka/KRaft Cost (When Running)

**Deleted Resources:**
- 12 Kafka brokers (c6g.xlarge spot)
- 5 KRaft controllers (smaller spot instances)
- 12× 50GB EBS volumes (brokers)
- 5× 30GB EBS volumes (controllers)

**Cost Breakdown:**

| Component | Monthly Cost | Calculation |
|-----------|--------------|-------------|
| **Kafka Broker Compute** | $100.32 | 12 × c6g.xlarge spot × 24h × 31d × $0.0116/h |
| **KRaft Controller Compute** | $24.08 | 5 × c6g.large spot × 24h × 31d × $0.0058/h |
| **Kafka Broker EBS** | $48.00 | 12 × 50GB × $0.08/GB |
| **KRaft Controller EBS** | $12.00 | 5 × 30GB × $0.08/GB |
| **TOTAL (Kafka Stack)** | **~$184** | Cost to run Kafka cluster |

**Full Stack Cost:** $256 (base) + $184 (Kafka) = **$440/month**

---

## Cost Comparison

| State | Monthly Cost | Savings vs Full Stack |
|-------|--------------|------------------------|
| **Full Stack** (Kafka + KRaft + Base, 1 system node) | $440 | - |
| **Current** (Base only, Kafka deleted, 1 system node) | $256 | **$184/month** |
| **Per Day Savings** (Kafka deleted) | - | **~$6/day** |
| **Savings vs 2 System Nodes** | - | **$65/month** |

---

## Next Step: Auto-Cleanup with Python Sidecar

**Goal:** Automatically delete CRDs after a specified date to prevent cost overruns

### Approach

Create a Kubernetes CronJob with a Python container that:
1. Checks current date against target deletion date
2. Deletes Kafka and KRaftController CRDs if past the date
3. Optionally sends notification (Slack, email)

### Implementation Options

#### Option 1: Simple CronJob (Recommended)

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-auto-cleanup
  namespace: confluent
spec:
  schedule: "0 0 * * *"  # Daily at midnight
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: kafka-cleanup
          containers:
          - name: cleanup
            image: python:3.11-slim
            command:
            - /bin/bash
            - -c
            - |
              pip install kubernetes python-dateutil
              python /scripts/cleanup.py
            env:
            - name: CLEANUP_DATE
              value: "2026-06-01"  # Delete after this date
            - name: DRY_RUN
              value: "false"
            volumeMounts:
            - name: cleanup-script
              mountPath: /scripts
          restartPolicy: OnFailure
          volumes:
          - name: cleanup-script
            configMap:
              name: kafka-cleanup-script
```

#### Option 2: Sidecar in Operator Pod

Add a sidecar container to the Confluent Operator pod that monitors date and triggers cleanup.

**Pros:**
- Always running alongside operator
- Can react immediately when date is reached

**Cons:**
- More complex to inject into operator deployment
- Higher resource usage (24/7)

### Recommended: CronJob Approach

**Why:**
- Simple, standard Kubernetes pattern
- Runs once per day (low overhead)
- Easy to test and debug
- Can be disabled/enabled easily

---

## Python Script (cleanup.py)

```python
#!/usr/bin/env python3
import os
from datetime import datetime
from kubernetes import client, config
from dateutil import parser

CLEANUP_DATE = os.getenv("CLEANUP_DATE", "2026-06-01")
DRY_RUN = os.getenv("DRY_RUN", "false").lower() == "true"
NAMESPACE = "confluent"

def main():
    # Load in-cluster config
    config.load_incluster_config()
    
    # Parse cleanup date
    cleanup_date = parser.parse(CLEANUP_DATE).date()
    current_date = datetime.now().date()
    
    print(f"Current date: {current_date}")
    print(f"Cleanup date: {cleanup_date}")
    print(f"Dry run: {DRY_RUN}")
    
    if current_date < cleanup_date:
        print(f"Not yet cleanup date. {(cleanup_date - current_date).days} days remaining.")
        return
    
    print(f"⚠️  Cleanup date reached! Deleting Kafka resources...")
    
    # Initialize custom objects API
    api = client.CustomObjectsApi()
    
    # Delete Kafka
    try:
        if not DRY_RUN:
            api.delete_namespaced_custom_object(
                group="platform.confluent.io",
                version="v1beta1",
                namespace=NAMESPACE,
                plural="kafkas",
                name="kafka"
            )
        print("✅ Deleted Kafka CR: kafka")
    except Exception as e:
        print(f"❌ Failed to delete Kafka: {e}")
    
    # Delete KRaftController
    try:
        if not DRY_RUN:
            api.delete_namespaced_custom_object(
                group="platform.confluent.io",
                version="v1beta1",
                namespace=NAMESPACE,
                plural="kraftcontrollers",
                name="kraftcontroller"
            )
        print("✅ Deleted KRaftController CR: kraftcontroller")
    except Exception as e:
        print(f"❌ Failed to delete KRaftController: {e}")
    
    print("🎉 Cleanup complete!")

if __name__ == "__main__":
    main()
```

---

## RBAC Configuration

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafka-cleanup
  namespace: confluent

---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kafka-cleanup
  namespace: confluent
rules:
- apiGroups: ["platform.confluent.io"]
  resources: ["kafkas", "kraftcontrollers"]
  verbs: ["get", "list", "delete"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: kafka-cleanup
  namespace: confluent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kafka-cleanup
subjects:
- kind: ServiceAccount
  name: kafka-cleanup
  namespace: confluent
```

---

## Deployment Steps

1. **Create cleanup script:**
   ```bash
   kubectl create configmap kafka-cleanup-script \
     --from-file=cleanup.py=/path/to/cleanup.py \
     -n confluent
   ```

2. **Deploy RBAC:**
   ```bash
   kubectl apply -f kafka/kafka-cleanup-rbac.yaml
   ```

3. **Deploy CronJob:**
   ```bash
   kubectl apply -f kafka/kafka-cleanup-cronjob.yaml
   ```

4. **Test (dry run):**
   ```bash
   # Trigger manual job
   kubectl create job --from=cronjob/kafka-auto-cleanup manual-test -n confluent
   
   # Check logs
   kubectl logs -n confluent -l job-name=manual-test
   ```

---

## Cost Impact of Auto-Cleanup

**CronJob overhead:** ~$0.50/month
- Runs daily for ~10 seconds
- Python:3.11-slim image: ~200MB
- Minimal CPU/memory

**Savings if cleanup triggers:** $184/month (Kafka stack deleted)

**ROI:** $184 saved / $0.50 cost = **36,700% ROI** 🎉

---

## Summary

| State | Monthly Cost | Daily Cost |
|-------|--------------|------------|
| **Current (Kafka deleted, 1 system node)** | $256 | $8.26 |
| **Full Stack (Kafka running, 1 system node)** | $440 | $14.19 |
| **Savings from Kafka deletion** | **-$184** | **-$5.94** |
| **Savings from 2→1 system nodes** | **-$65** | **-$2.10** |
| **Total savings vs original (2 nodes + Kafka)** | **-$249** | **-$8.03** |

**Configuration:**
- 1 system node (t3.large on-demand)
- Kafka/KRaft deleted
- Auto-cleanup CronJob ready to deploy

**⚠️ DNS Note:** With only 1 system node, there's no redundancy for DNS resolution from jumpbox. If the node is replaced, DNS breaks until Terraform is re-applied. Consider this acceptable for demo/test environments.

**Next Step:** Apply Terraform to reduce system nodes from 2 to 1.
