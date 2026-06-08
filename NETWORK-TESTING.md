# Network Performance Testing

Cross-AZ network throughput testing for Kafka cluster infrastructure using Python-based netperf tool.

## Overview

This deployment creates 3 debug pods spread across different availability zones on the same Karpenter-managed ARM64 nodes as the Kafka cluster. Each pod runs a continuous netperf server for cross-AZ network performance testing.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ EKS Cluster - Karpenter ARM64 NodePools                    │
│                                                              │
│  AZ1 (us-east-1a)      AZ2 (us-east-1b)      AZ3 (us-east-1c) │
│  ┌──────────────┐      ┌──────────────┐      ┌──────────────┐ │
│  │ busybox-     │      │ busybox-     │      │ busybox-     │ │
│  │ debug-0      │◄────►│ debug-1      │◄────►│ debug-2      │ │
│  │              │      │              │      │              │ │
│  │ netperf      │      │ netperf      │      │ netperf      │ │
│  │ server:5001  │      │ server:5001  │      │ server:5001  │ │
│  └──────────────┘      └──────────────┘      └──────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Features

- **3 StatefulSet pods** with predictable names (`busybox-debug-0`, `busybox-debug-1`, `busybox-debug-2`)
- **Anti-affinity scheduling** ensures one pod per availability zone
- **Python 3.11 Alpine** lightweight container (~50MB)
- **netperf.py server** runs automatically on port 5001 on each pod
- **Same node targeting** as Kafka brokers (ARM64 spot instances via Karpenter)
- **Same tolerations** (`arch=arm64:NoSchedule`)

## Deployment

### Deploy the Test Pods

```bash
kubectl apply -f busybox-debug-deployment.yaml
```

### Verify Distribution Across AZs

```bash
kubectl get pods -n confluent -l app=busybox-debug -o wide
```

**Expected output:**
```
NAME              READY   STATUS    IP            NODE                          AZ
busybox-debug-0   1/1     Running   10.19.1.45    ip-10-19-1-234.ec2.internal   us-east-1a
busybox-debug-1   1/1     Running   10.19.2.67    ip-10-19-2-123.ec2.internal   us-east-1b
busybox-debug-2   1/1     Running   10.19.3.89    ip-10-19-3-156.ec2.internal   us-east-1c
```

### Check Server Logs

Each pod automatically runs a netperf server. Verify it's running:

```bash
kubectl logs busybox-debug-0 -n confluent
kubectl logs busybox-debug-1 -n confluent
kubectl logs busybox-debug-2 -n confluent
```

**Expected output:**
```
Starting netperf server on port 5001...
Server listening on port 5001
```

## Running Network Tests

### Get Pod IPs

```bash
POD0_IP=$(kubectl get pod busybox-debug-0 -n confluent -o jsonpath='{.status.podIP}')
POD1_IP=$(kubectl get pod busybox-debug-1 -n confluent -o jsonpath='{.status.podIP}')
POD2_IP=$(kubectl get pod busybox-debug-2 -n confluent -o jsonpath='{.status.podIP}')

echo "Pod 0 IP: $POD0_IP"
echo "Pod 1 IP: $POD1_IP"
echo "Pod 2 IP: $POD2_IP"
```

### Test Scenarios

#### 1. Cross-AZ Test: Pod-0 → Pod-1

Test network throughput from AZ1 to AZ2:

```bash
kubectl exec -it busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 1000 -b 65536
```

#### 2. Cross-AZ Test: Pod-0 → Pod-2

Test network throughput from AZ1 to AZ3:

```bash
kubectl exec -it busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d 1000 -b 65536
```

#### 3. Cross-AZ Test: Pod-1 → Pod-2

Test network throughput from AZ2 to AZ3:

```bash
kubectl exec -it busybox-debug-1 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d 1000 -b 65536
```

### Understanding Test Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `-m client` | - | Run in client mode (send data) |
| `-a <IP>` | Pod IP | Target server IP address |
| `-p 5001` | 5001 | Port number (server listening port) |
| `-d 1000` | 1000 MB | Amount of data to send (1 GB) |
| `-b 65536` | 64 KB | TCP buffer size |

### Sample Output

```
Data sent: 1000.0 MB
Time taken: 8.34 seconds
Transfer speed: 119.90 MB/s
```

## Full Test Suite

Run a complete cross-AZ matrix test using the included script:

```bash
./network-test.sh
```

This automated script will:
1. Verify all 3 pods are running
2. Display pod distribution across AZs
3. Run 6 cross-AZ network throughput tests (all combinations)
4. Display summary results

**Manual test script:**

```bash
#!/bin/bash
# Get pod IPs
POD0_IP=$(kubectl get pod busybox-debug-0 -n confluent -o jsonpath='{.status.podIP}')
POD1_IP=$(kubectl get pod busybox-debug-1 -n confluent -o jsonpath='{.status.podIP}')
POD2_IP=$(kubectl get pod busybox-debug-2 -n confluent -o jsonpath='{.status.podIP}')

echo "=== Network Performance Test Matrix ==="
echo ""

echo "Test 1: Pod-0 → Pod-1 (AZ1 → AZ2)"
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 1000 -b 65536
echo ""

echo "Test 2: Pod-0 → Pod-2 (AZ1 → AZ3)"
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d 1000 -b 65536
echo ""

echo "Test 3: Pod-1 → Pod-0 (AZ2 → AZ1)"
kubectl exec busybox-debug-1 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD0_IP -p 5001 -d 1000 -b 65536
echo ""

echo "Test 4: Pod-1 → Pod-2 (AZ2 → AZ3)"
kubectl exec busybox-debug-1 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d 1000 -b 65536
echo ""

echo "Test 5: Pod-2 → Pod-0 (AZ3 → AZ1)"
kubectl exec busybox-debug-2 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD0_IP -p 5001 -d 1000 -b 65536
echo ""

echo "Test 6: Pod-2 → Pod-1 (AZ3 → AZ2)"
kubectl exec busybox-debug-2 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 1000 -b 65536
echo ""

echo "=== All tests completed ==="
```

## Expected Performance

### AWS Cross-AZ Network Performance

Typical cross-AZ network throughput on AWS (eu-west-1):

| Instance Type | Expected Throughput | Notes |
|---------------|-------------------|-------|
| t4g.medium | 100-200 MB/s | Baseline with bursting |
| t4g.large | 150-300 MB/s | Baseline with bursting |
| c6g.large | 300-500 MB/s | Network optimized |
| c6g.xlarge | 500-800 MB/s | Network optimized |
| m6g.large | 300-500 MB/s | Balanced |

**Factors affecting performance:**
- Instance type and size
- Network credits (for t4g burstable instances)
- Cross-AZ latency (typically 1-3ms)
- TCP buffer size
- Network congestion

## Advanced Testing

### Custom Buffer Sizes

Test with different TCP buffer sizes:

```bash
# Small buffer (8 KB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 100 -b 8192

# Medium buffer (64 KB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 100 -b 65536

# Large buffer (256 KB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 100 -b 262144
```

### Different Data Sizes

```bash
# Quick test (100 MB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 100 -b 65536

# Standard test (1 GB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 1000 -b 65536

# Large test (5 GB)
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d 5000 -b 65536
```

## Troubleshooting

### Pods Not Spreading Across AZs

```bash
# Check pod anti-affinity
kubectl get pods -n confluent -l app=busybox-debug -o yaml | grep -A 10 affinity

# Check available nodes per AZ
kubectl get nodes -L topology.kubernetes.io/zone
```

### Server Not Responding

```bash
# Check if server is running
kubectl logs busybox-debug-0 -n confluent --tail=20

# Check if port is listening
kubectl exec busybox-debug-0 -n confluent -- netstat -tlnp | grep 5001

# Restart the pod
kubectl delete pod busybox-debug-0 -n confluent
```

### Connection Refused

```bash
# Verify pod IP
kubectl get pod busybox-debug-1 -n confluent -o jsonpath='{.status.podIP}'

# Test connectivity
kubectl exec busybox-debug-0 -n confluent -- ping -c 3 $POD1_IP

# Check network policies
kubectl get networkpolicies -n confluent
```

### Low Throughput

Possible causes:
- **Instance type**: t4g.medium has limited network bandwidth
- **Network credits exhausted**: Burstable instances (t4g) have network credit limits
- **Small buffer size**: Try increasing `-b` parameter
- **Short test duration**: Use larger `-d` value for more accurate results

## Cleanup

Remove the test pods:

```bash
kubectl delete -f busybox-debug-deployment.yaml
```

This will delete:
- StatefulSet `busybox-debug`
- All 3 pods
- ConfigMap `netperf-script`
- Service `busybox-debug`

## Files

- `busybox-debug-deployment.yaml` - Complete deployment manifest (3 pods with netperf servers)
- `network-test.sh` - Automated test suite script
- `busybox-debug.yaml` - Original single-pod deployment (deprecated)
- `NETWORK-TESTING.md` - This documentation

## Related Documentation

- [README.md](README.md) - Main project documentation
- [OPERATIONS.md](OPERATIONS.md) - Operational procedures
- [kafka/README.md](kafka/README.md) - Kafka deployment guide
