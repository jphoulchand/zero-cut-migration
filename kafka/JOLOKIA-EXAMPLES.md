# Jolokia Query Examples

Jolokia is enabled by default on **port 7777** in Confluent for Kubernetes.

## Setup

```bash
# Port-forward to a Kafka broker
kubectl port-forward -n confluent kafka-0 7777:7777

# Or from jumpbox (if you have VPC peering)
ssh -L 7777:kafka-0.kafka.confluent.svc.cluster.local:7777 ec2-user@<jumpbox-ip>
```

## Basic Queries

### Version & Info
```bash
curl http://localhost:7777/jolokia/version | jq .
```

### List All MBeans
```bash
curl http://localhost:7777/jolokia/list | jq . | less
```

### Search for Specific MBeans
```bash
curl http://localhost:7777/jolokia/search/kafka.server:type=BrokerTopicMetrics,* | jq .
```

## Broker Metrics

### Messages In Per Second (All Topics)
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec | jq .
```

### Bytes In/Out Per Second
```bash
# Bytes in
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=BytesInPerSec | jq .value.OneMinuteRate

# Bytes out
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=BytesOutPerSec | jq .value.OneMinuteRate
```

### Per-Topic Metrics
```bash
# Replace <topic-name> with your topic
curl "http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec,topic=<topic-name>" | jq .
```

## Replication Health

### Under-Replicated Partitions (Should be 0)
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions | jq .value.Value
```

### Offline Partitions (Should be 0)
```bash
curl http://localhost:7777/jolokia/read/kafka.controller:type=KafkaController,name=OfflinePartitionsCount | jq .value.Value
```

### Partition Count
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=PartitionCount | jq .value.Value
```

### Leader Count
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=ReplicaManager,name=LeaderCount | jq .value.Value
```

## Controller Metrics

### Active Controller Count (1 broker should be 1, others 0)
```bash
curl http://localhost:7777/jolokia/read/kafka.controller:type=KafkaController,name=ActiveControllerCount | jq .value.Value
```

### Preferred Replica Imbalance Count
```bash
curl http://localhost:7777/jolokia/read/kafka.controller:type=KafkaController,name=PreferredReplicaImbalanceCount | jq .
```

## Request Metrics

### Request Handler Pool Idle Percent (Should be > 20%)
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent | jq .value.OneMinuteRate
```

### Total Request Rate
```bash
curl "http://localhost:7777/jolokia/read/kafka.network:type=RequestMetrics,name=RequestsPerSec,request=Produce" | jq .value.OneMinuteRate
```

### Request Latency
```bash
# Produce request latency (99th percentile)
curl "http://localhost:7777/jolokia/read/kafka.network:type=RequestMetrics,name=TotalTimeMs,request=Produce/99thPercentile" | jq .value
```

## JVM Metrics

### Heap Memory Usage
```bash
curl http://localhost:7777/jolokia/read/java.lang:type=Memory/HeapMemoryUsage | jq .value
```

### GC Count & Time
```bash
# G1 Young Generation GC
curl "http://localhost:7777/jolokia/read/java.lang:type=GarbageCollector,name=G1 Young Generation" | jq .value

# G1 Old Generation GC
curl "http://localhost:7777/jolokia/read/java.lang:type=GarbageCollector,name=G1 Old Generation" | jq .value
```

### Thread Count
```bash
curl http://localhost:7777/jolokia/read/java.lang:type=Threading/ThreadCount | jq .value
```

## Network Metrics

### Network Processor Avg Idle Percent
```bash
curl http://localhost:7777/jolokia/read/kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent | jq .value
```

### Connection Count
```bash
curl http://localhost:7777/jolokia/read/kafka.server:type=socket-server-metrics,listener=REPLICATION/connection-count | jq .value
```

## Log Metrics

### Log Flush Rate
```bash
curl http://localhost:7777/jolokia/read/kafka.log:type=LogFlushStats,name=LogFlushRateAndTimeMs | jq .
```

### Log Segment Count
```bash
curl http://localhost:7777/jolokia/read/kafka.log:type=Log,name=NumLogSegments,topic=*,partition=* | jq .
```

## Batch Read Multiple Metrics

```bash
curl -X POST http://localhost:7777/jolokia \
  -H "Content-Type: application/json" \
  -d '[
    {"type":"read","mbean":"kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec"},
    {"type":"read","mbean":"kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions"},
    {"type":"read","mbean":"kafka.controller:type=KafkaController,name=ActiveControllerCount"}
  ]' | jq .
```

## Health Check Script

Create a simple health check:

```bash
#!/bin/bash
# kafka-health-check.sh

BROKER=${1:-localhost:7777}

echo "=== Kafka Broker Health Check ==="
echo "Broker: $BROKER"
echo

# Under-replicated partitions
URP=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=UnderReplicatedPartitions" | jq -r '.value.Value')
echo "Under-Replicated Partitions: $URP (should be 0)"

# Offline partitions
OFFLINE=$(curl -s "http://$BROKER/jolokia/read/kafka.controller:type=KafkaController,name=OfflinePartitionsCount" | jq -r '.value.Value // 0')
echo "Offline Partitions: $OFFLINE (should be 0)"

# Request handler idle
IDLE=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=KafkaRequestHandlerPool,name=RequestHandlerAvgIdlePercent" | jq -r '.value.OneMinuteRate')
echo "Request Handler Idle %: $IDLE (should be > 0.2)"

# Leader count
LEADERS=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=LeaderCount" | jq -r '.value.Value')
echo "Leader Count: $LEADERS"

# Partition count
PARTITIONS=$(curl -s "http://$BROKER/jolokia/read/kafka.server:type=ReplicaManager,name=PartitionCount" | jq -r '.value.Value')
echo "Partition Count: $PARTITIONS"

if [ "$URP" -eq 0 ] && [ "$OFFLINE" -eq 0 ] && [ "$(echo "$IDLE > 0.2" | bc -l)" -eq 1 ]; then
  echo -e "\n✅ Broker is HEALTHY"
  exit 0
else
  echo -e "\n❌ Broker has ISSUES"
  exit 1
fi
```

Usage:
```bash
chmod +x kafka-health-check.sh
./kafka-health-check.sh localhost:7777
```

## Authentication

If Jolokia access control is enabled (not currently), use:

```bash
curl -u admin:admin-secret http://localhost:7777/jolokia/read/...
```

## Access from Prometheus

Configure Prometheus to scrape Jolokia metrics:

```yaml
scrape_configs:
  - job_name: 'kafka-jolokia'
    metrics_path: '/jolokia/read'
    params:
      mbean: ['kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec']
    static_configs:
      - targets: ['kafka-0.kafka.confluent.svc.cluster.local:7777']
```

## References

- [Jolokia Documentation](https://jolokia.org/reference/html/)
- [Kafka Monitoring](https://kafka.apache.org/documentation/#monitoring)
- [Confluent JMX Monitoring](https://docs.confluent.io/platform/current/kafka/monitoring.html)
