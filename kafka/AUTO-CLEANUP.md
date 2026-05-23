# Kafka Auto-Cleanup with Date-Based Deletion

Automatically delete Kafka and KRaftController CRDs after a specified date to prevent cost overruns.

---

## Overview

- **What:** CronJob that deletes Kafka resources when current date > cleanup date
- **Why:** Prevent demo/test clusters from running indefinitely and incurring costs
- **Cost Impact:** Saves **$184/month** when triggered ($6/day)
- **Overhead:** ~$0.50/month for CronJob execution

---

## Architecture

```
┌─────────────────────┐
│  Secret             │
│  cleanup-date:      │◄──── Update this to change cleanup date
│  "2026-06-30"       │
└──────────┬──────────┘
           │
           │ (read)
           ▼
┌─────────────────────┐
│  CronJob            │
│  Runs daily @ 2 AM  │
│  - Read secret      │
│  - Compare dates    │
│  - Delete if past   │
└──────────┬──────────┘
           │
           │ (delete if overdue)
           ▼
┌─────────────────────┐
│  Kafka Resources    │
│  - kafka CR         │
│  - kraftcontroller  │
└─────────────────────┘
```

---

## Files

```
kafka/
├── kafka-cleanup-secret.yaml     # Cleanup date configuration
├── kafka-cleanup-rbac.yaml       # ServiceAccount + permissions
├── kafka-cleanup-cronjob.yaml    # Daily job definition
├── cleanup.py                    # Python deletion script
└── AUTO-CLEANUP.md              # This file
```

---

## Deployment

### 1. Create ConfigMap with Python Script

```bash
kubectl create configmap kafka-cleanup-script \
  --from-file=cleanup.py=kafka/cleanup.py \
  -n confluent
```

### 2. Deploy RBAC (ServiceAccount + Role)

```bash
kubectl apply -f kafka/kafka-cleanup-rbac.yaml
```

Expected output:
```
serviceaccount/kafka-cleanup created
role.rbac.authorization.k8s.io/kafka-cleanup created
rolebinding.rbac.authorization.k8s.io/kafka-cleanup created
```

### 3. Create Secret with Cleanup Date

```bash
kubectl apply -f kafka/kafka-cleanup-secret.yaml
```

**Default cleanup date:** `2026-06-30`

### 4. Deploy CronJob

```bash
kubectl apply -f kafka/kafka-cleanup-cronjob.yaml
```

Expected output:
```
cronjob.batch/kafka-auto-cleanup created
```

---

## Configuration

### Update Cleanup Date

Edit the secret to change when cleanup happens:

```bash
kubectl edit secret kafka-cleanup-config -n confluent
```

Change `cleanup-date` to your desired date (YYYY-MM-DD):

```yaml
stringData:
  cleanup-date: "2026-07-15"  # Delete after July 15, 2026
  dry-run: "false"
```

Or update via kubectl:

```bash
kubectl create secret generic kafka-cleanup-config \
  --from-literal=cleanup-date=2026-07-15 \
  --from-literal=dry-run=false \
  --dry-run=client -o yaml | kubectl apply -f - -n confluent
```

### Enable Dry Run (Test Mode)

Test without actually deleting:

```bash
kubectl patch secret kafka-cleanup-config -n confluent \
  --type merge \
  -p '{"stringData":{"dry-run":"true"}}'
```

### Change Schedule

Edit the CronJob schedule (default: daily at 2 AM UTC):

```bash
kubectl edit cronjob kafka-auto-cleanup -n confluent
```

Change the `schedule` field:
```yaml
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM UTC
  # schedule: "0 */6 * * *"  # Every 6 hours
  # schedule: "*/30 * * * *"  # Every 30 minutes (for testing)
```

---

## Testing

### Manual Trigger (Dry Run)

```bash
# Set dry-run to true
kubectl patch secret kafka-cleanup-config -n confluent \
  --type merge \
  -p '{"stringData":{"dry-run":"true"}}'

# Trigger job manually
kubectl create job --from=cronjob/kafka-auto-cleanup manual-test-1 -n confluent

# Watch logs
kubectl logs -n confluent -l job-name=manual-test-1 -f
```

Expected output (if date not reached):
```
✓ Loaded in-cluster Kubernetes config
✓ Read secret: cleanup-date=2026-06-30, dry-run=true
============================================================
Current date:  2026-05-23
Cleanup date:  2026-06-30
Dry run:       True
============================================================

⏳ Cleanup date not reached yet. 38 day(s) remaining.
✓ No action taken
```

### Manual Trigger (Set Past Date)

Test actual deletion by setting a past date:

```bash
# Set cleanup date to yesterday
kubectl patch secret kafka-cleanup-config -n confluent \
  --type merge \
  -p '{"stringData":{"cleanup-date":"2026-05-22","dry-run":"true"}}'

# Trigger job
kubectl create job --from=cronjob/kafka-auto-cleanup manual-test-2 -n confluent

# Check logs
kubectl logs -n confluent -l job-name=manual-test-2 -f
```

Expected output:
```
⚠️  Cleanup date OVERDUE by 1 day(s)!
============================================================
DELETING KAFKA RESOURCES
============================================================

[DRY RUN] Would delete kafkas/kafka
[DRY RUN] Would delete kraftcontrollers/kraftcontroller

============================================================
✓ DRY RUN COMPLETE - No resources deleted
============================================================
```

### Actual Deletion Test

```bash
# Deploy Kafka first (if not running)
kubectl apply -f kafka/kafka-core.yaml

# Wait for pods to start
kubectl get pods -n confluent -w

# Set cleanup date to past + disable dry-run
kubectl patch secret kafka-cleanup-config -n confluent \
  --type merge \
  -p '{"stringData":{"cleanup-date":"2026-05-22","dry-run":"false"}}'

# Trigger cleanup
kubectl create job --from=cronjob/kafka-auto-cleanup cleanup-test -n confluent

# Watch deletion
kubectl get pods -n confluent -w
```

---

## Monitoring

### Check CronJob Status

```bash
# View CronJob
kubectl get cronjob kafka-auto-cleanup -n confluent

# View recent jobs
kubectl get jobs -n confluent -l app=kafka-cleanup

# View last 3 runs
kubectl get jobs -n confluent --sort-by=.metadata.creationTimestamp | tail -3
```

### View Job Logs

```bash
# List all cleanup jobs
kubectl get jobs -n confluent -l app=kafka-cleanup

# View logs from latest job
kubectl logs -n confluent -l job-name=<job-name>

# Stream logs from running job
kubectl logs -n confluent -l app=kafka-cleanup -f
```

### Check Next Scheduled Run

```bash
kubectl get cronjob kafka-auto-cleanup -n confluent -o json | jq -r '.status.lastScheduleTime, .status.lastSuccessfulTime'
```

---

## Cleanup

### Delete Auto-Cleanup System

```bash
kubectl delete cronjob kafka-auto-cleanup -n confluent
kubectl delete -f kafka/kafka-cleanup-rbac.yaml
kubectl delete secret kafka-cleanup-config -n confluent
kubectl delete configmap kafka-cleanup-script -n confluent
```

---

## How It Works

1. **CronJob runs daily** at 2 AM UTC (configurable)

2. **Python script executes:**
   - Loads in-cluster Kubernetes config
   - Reads `kafka-cleanup-config` secret
   - Parses `cleanup-date` (YYYY-MM-DD format)
   - Compares current date vs cleanup date

3. **If current date < cleanup date:**
   - Log days remaining
   - Exit (no action)

4. **If current date >= cleanup date:**
   - Delete `kafkas/kafka` CR
   - Delete `kraftcontrollers/kraftcontroller` CR
   - Log success or errors

5. **Confluent Operator reacts:**
   - Detects CR deletion
   - Deletes Kafka pods, PVCs, services
   - Karpenter scales down nodes (if no other workloads)

---

## Cost Savings

| State | Monthly Cost | Savings |
|-------|--------------|---------|
| **Kafka Running** | $505 | - |
| **After Auto-Cleanup** | $321 | **$184/month** |

**Daily savings:** $6/day

**CronJob overhead:** ~$0.50/month

**ROI:** 36,700% 🚀

---

## Security Notes

- **RBAC Principle of Least Privilege:**
  - ServiceAccount can only read `kafka-cleanup-config` secret
  - Can only delete `kafkas` and `kraftcontrollers` in `confluent` namespace
  - Cannot delete other resources or access other namespaces

- **Date Validation:**
  - Script validates date format (YYYY-MM-DD)
  - Fails safely if secret missing or malformed

- **Dry Run Mode:**
  - Always test with `dry-run: "true"` first
  - Prevents accidental deletion

---

## Troubleshooting

### Job Fails with "Forbidden"

Check RBAC permissions:
```bash
kubectl auth can-i get secrets --as=system:serviceaccount:confluent:kafka-cleanup -n confluent
kubectl auth can-i delete kafkas --as=system:serviceaccount:confluent:kafka-cleanup -n confluent
```

Should return `yes` for both.

### Job Fails with "Secret not found"

Ensure secret exists:
```bash
kubectl get secret kafka-cleanup-config -n confluent
```

### Job Never Runs

Check CronJob schedule:
```bash
kubectl get cronjob kafka-auto-cleanup -n confluent -o yaml | grep schedule
```

Force a manual run:
```bash
kubectl create job --from=cronjob/kafka-auto-cleanup manual-run -n confluent
```

### Cleanup Happens But Resources Still Exist

Check if Confluent Operator is running:
```bash
kubectl get pods -n confluent -l app=confluent-operator
```

Operator must be running to process CR deletions.

---

## Best Practices

1. **Set cleanup date conservatively:**
   - Add buffer days for demos/tests
   - Example: Demo on June 15 → set cleanup date to July 1

2. **Always test with dry-run first:**
   - Verify date logic works
   - Check logs for expected behavior

3. **Monitor the first few runs:**
   - Check job logs after deployment
   - Verify date comparison is correct

4. **Update date before it expires:**
   - If you need to extend, update secret before cleanup date
   - Script runs daily, so you have a window to update

5. **Keep job history:**
   - Default: 3 successful + 3 failed jobs
   - Useful for debugging and audit trail

---

## Alternative: Time-to-Live (TTL) Approach

Instead of a specific date, you could implement TTL-based cleanup:

```yaml
# Secret with TTL in days
stringData:
  ttl-days: "30"  # Delete 30 days after creation
  creation-date: "2026-05-23"
```

This would be more flexible for repeated deployments. Let me know if you want this variant!

---

## References

- Kubernetes CronJobs: https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/
- Confluent Operator CRDs: https://docs.confluent.io/operator/current/co-custom-resources.html
- Cost Analysis: `/COST-ANALYSIS-CURRENT.md`
