# Kafka Replication Performance Monitoring

## Overview

Replication performance is critical for high-throughput Kafka clusters. This guide shows how to monitor and troubleshoot replication bottlenecks.

## Key Replication Metrics

### 1. Replication Lag (Most Important)

**MaxLag** - How far behind followers are from the leader:

```bash
# Check max lag across all partitions (should be close to 0)
kubectl port-forward -n confluent kafka-0 7777:7777 &

curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica | jq .value.Value
```

**Expected:** 0-10 messages (good), >1000 (investigate)

### 2. Replication Bytes In/Out Per Second

```bash
# Replication bytes in (data being replicated TO this broker)
curl -s http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesInPerSec | jq .value.OneMinuteRate

# Replication bytes out (data being replicated FROM this broker)
curl -s http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesOutPerSec | jq .value.OneMinuteRate
```

**What to look for:**
- ReplicationBytesIn should be roughly (RF-1) × BytesInPerSec
- For RF=5: ReplicationBytesIn ≈ 4 × BytesInPerSec
- Low replication bytes = replication bottleneck

### 3. ISR Shrink/Expand Rate

```bash
# ISR shrinks (bad - replicas falling behind)
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=IsrShrinksPerSec | jq .value.OneMinuteRate

# ISR expands (recovery after shrink)
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=IsrExpandsPerSec | jq .value.OneMinuteRate
```

**Expected:** Both should be 0 in steady state
**Problem:** ISR shrinks > 0 means replicas can't keep up

### 4. Replica Fetcher Metrics

```bash
# Fetch request rate from followers
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaFetcherManager,name=RequestsPerSec,clientId=Replica | jq .value.OneMinuteRate

# Bytes per fetch request
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaFetcherManager,name=BytesPerSec,clientId=Replica | jq .value.OneMinuteRate
```

### 5. Network Request Queue Time

```bash
# Request queue time for Fetch requests (from followers)
curl -s "http://localhost:7777/jolokia/read/kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=Fetch" | jq .value.Mean

# Total time for Fetch requests
curl -s "http://localhost:7777/jolokia/read/kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Fetch" | jq .value.Mean
```

**Expected:** <50ms request queue time
**Problem:** >100ms means broker is overloaded

## Complete Replication Health Check Script

```bash
#!/bin/bash
# replication-health.sh

BROKER=${1:-localhost:7777}

echo "=== Kafka Replication Performance Check ==="
echo "Broker: $BROKER"
echo

# Max lag
MAX_LAG=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica" | jq -r '.value.Value // 0')
echo "Max Replication Lag: $MAX_LAG messages"

# Under-replicated partitions
URP=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions" | jq -r '.value.Value')
echo "Under-Replicated Partitions: $URP"

# ISR shrinks/expands
ISR_SHRINKS=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=IsrShrinksPerSec" | jq -r '.value.OneMinuteRate')
ISR_EXPANDS=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=IsrExpandsPerSec" | jq -r '.value.OneMinuteRate')
echo "ISR Shrinks/sec: $ISR_SHRINKS"
echo "ISR Expands/sec: $ISR_EXPANDS"

# Replication throughput
REP_BYTES_IN=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesInPerSec" | jq -r '.value.OneMinuteRate')
REP_BYTES_OUT=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesOutPerSec" | jq -r '.value.OneMinuteRate')
echo "Replication Bytes In/sec: $(echo "scale=2; $REP_BYTES_IN / 1024 / 1024" | bc) MB/s"
echo "Replication Bytes Out/sec: $(echo "scale=2; $REP_BYTES_OUT / 1024 / 1024" | bc) MB/s"

# Producer throughput for comparison
BYTES_IN=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec" | jq -r '.value.OneMinuteRate')
echo "Producer Bytes In/sec: $(echo "scale=2; $BYTES_IN / 1024 / 1024" | bc) MB/s"

# Fetch request latency
FETCH_TIME=$(curl -s "http://$BROKER/jolokia/read/kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Fetch" | jq -r '.value.Mean // 0')
FETCH_QUEUE=$(curl -s "http://$BROKER/jolokia/read/kafka.network:type=RequestMetrics,name=RequestQueueTimeMs,request=Fetch" | jq -r '.value.Mean // 0')
echo "Fetch Total Time: ${FETCH_TIME}ms"
echo "Fetch Queue Time: ${FETCH_QUEUE}ms"

echo
if [ "$URP" -eq 0 ] && [ "$MAX_LAG" -lt 100 ] && (( $(echo "$ISR_SHRINKS < 0.1" | bc -l) )); then
  echo "✅ Replication is HEALTHY"
else
  echo "❌ Replication has ISSUES"
  [ "$URP" -gt 0 ] && echo "  - Under-replicated partitions detected"
  [ "$MAX_LAG" -gt 100 ] && echo "  - High replication lag"
  (( $(echo "$ISR_SHRINKS > 0.1" | bc -l) )) && echo "  - ISR shrinking (replicas falling behind)"
fi
```

## Per-Topic Replication Metrics

```bash
# Check replication lag for specific topic
TOPIC="partition5-rf5"

# Replication bytes in for this topic
curl -s "http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesInPerSec,topic=$TOPIC" | jq .value.OneMinuteRate

# Producer bytes in for comparison
curl -s "http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec,topic=$TOPIC" | jq .value.OneMinuteRate
```

## Monitoring During Performance Test

Run this while your producer perf test is running:

```bash
#!/bin/bash
# watch-replication.sh

echo "Topic,Timestamp,ProducerMBps,ReplicationMBps,MaxLag,ISRShrinks,FetchTimeMs"

while true; do
  TIMESTAMP=$(date +%s)
  
  # Producer throughput
  BYTES_IN=$(curl -s "http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec,topic=partition5-rf5" | jq -r '.value.OneMinuteRate // 0')
  PRODUCER_MBPS=$(echo "scale=2; $BYTES_IN / 1024 / 1024" | bc)
  
  # Replication throughput
  REP_BYTES=$(curl -s "http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=ReplicationBytesInPerSec,topic=partition5-rf5" | jq -r '.value.OneMinuteRate // 0')
  REP_MBPS=$(echo "scale=2; $REP_BYTES / 1024 / 1024" | bc)
  
  # Max lag
  MAX_LAG=$(curl -s "http://localhost:7777/jolokia/read/kafka.server:type=ReplicaFetcherManager,name=MaxLag,clientId=Replica" | jq -r '.value.Value // 0')
  
  # ISR shrinks
  ISR_SHRINKS=$(curl -s "http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=IsrShrinksPerSec" | jq -r '.value.OneMinuteRate // 0')
  
  # Fetch time
  FETCH_TIME=$(curl -s "http://localhost:7777/jolokia/read/kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Fetch" | jq -r '.value.Mean // 0')
  
  echo "partition5-rf5,$TIMESTAMP,$PRODUCER_MBPS,$REP_MBPS,$MAX_LAG,$ISR_SHRINKS,$FETCH_TIME"
  
  sleep 5
done
```

Usage:
```bash
# Start monitoring
./watch-replication.sh > replication-metrics.csv

# In another terminal, run your perf test
kafka-producer-perf-test --topic partition5-rf5 ...

# Stop monitoring (Ctrl+C)
# Analyze the CSV
```

## Common Replication Bottlenecks

### 1. Network Bandwidth Limit

**Symptom:** High producer throughput but low replication throughput

**Check:**
```bash
# Network throughput per broker
kubectl exec -n confluent kafka-0 -- iftop -i eth0 -t -s 5 2>/dev/null || \
kubectl exec -n confluent kafka-0 -- cat /proc/net/dev
```

**Fix:**
- Use larger instance types with more network bandwidth
- Check if hitting AWS network limits (t4g.medium = 5 Gbps burst)

### 2. Disk I/O Bottleneck

**Symptom:** High log flush latency, low replication throughput

**Check:**
```bash
# Log flush rate and time
curl -s http://localhost:7777/jolokia/read/kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs | jq .

# I/O wait time
kubectl exec -n confluent kafka-0 -- iostat -x 1 5
```

**Fix:**
- Use gp3 with higher IOPS (currently 3000 default, can increase to 16000)
- Increase `num.io.threads` (currently 8)
- Batch writes with `linger.ms`

### 3. Too Many Replicas/Partitions

**Symptom:** ISR shrinks, high MaxLag, under-replicated partitions

**Your case:** RF=5 is very high (industry standard is RF=3)

**Check:**
```bash
# Partition count
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=PartitionCount | jq .value.Value

# Leader count
curl -s http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=LeaderCount | jq .value.Value
```

**Fix:**
- Reduce replication factor to 3 (standard for production)
- Set `min.insync.replicas=2` instead of 3
- Fewer replicas = faster replication

### 4. CPU Bottleneck

**Symptom:** High request queue time, low idle handler %

**Check:**
```bash
# Request handler idle %
curl -s http://localhost:7777/jolokia/read/kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent | jq .value.OneMinuteRate

# Should be > 0.2 (20% idle)
```

**Fix:**
- Increase `num.network.threads` (currently 8)
- Scale horizontally (more brokers)

## Recommended Kafka Configuration for High Throughput

```yaml
# In kafka-core.yaml configOverrides
configOverrides:
  server:
  # Network threads (increase for high throughput)
  - "num.network.threads=16"  # Currently 8
  
  # I/O threads (increase for high disk I/O)
  - "num.io.threads=16"  # Currently 8
  
  # Replica fetcher threads (increase for many partitions)
  - "num.replica.fetchers=8"  # Default: 1
  
  # Socket buffer sizes (increase for high throughput)
  - "socket.send.buffer.bytes=1048576"  # 1MB
  - "socket.receive.buffer.bytes=1048576"  # 1MB
  - "replica.socket.receive.buffer.bytes=1048576"  # 1MB
  
  # Fetch sizes (increase for larger batches)
  - "replica.fetch.max.bytes=10485760"  # 10MB
  - "replica.fetch.response.max.bytes=104857600"  # 100MB
  
  # Log flush (tune for latency vs durability)
  - "log.flush.interval.messages=10000"
  - "log.flush.interval.ms=1000"
```

## Your Current Performance Analysis

Based on your test results:
- **Producer throughput:** 56.42 MB/sec average
- **Latency:** 513ms average (moderate)
- **RF=5, min.insync.replicas=3** - Very safe but slower

**Expected replication bandwidth for RF=5:**
- Producer: 56 MB/s
- Replication needed: 56 MB/s × 4 replicas = **224 MB/s**
- Per broker replication: ~224 MB/s ÷ 12 brokers = **18-20 MB/s**

**If customer saw 1 MBps:** This is 56× slower, likely due to:
1. Network bandwidth limits
2. Single broker handling too many replicas
3. Disk I/O saturation
4. t4g.medium instance limits (check instance type)

## Next Steps

1. **Run monitoring during test:**
   ```bash
   kubectl port-forward -n confluent kafka-0 7777:7777 &
   ./watch-replication.sh > metrics.csv &
   kafka-producer-perf-test ...
   ```

2. **Check for bottlenecks:**
   ```bash
   ./replication-health.sh localhost:7777
   ```

3. **Tune configuration** if needed (see above)

4. **Consider reducing RF to 3** for better performance
