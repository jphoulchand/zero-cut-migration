# Kafka JMX Monitoring with Jolokia & Prometheus

## Overview

Confluent for Kubernetes (CFK) includes **built-in JMX monitoring** with three ports:

- **Port 7203**: JMX (remote JMX access)
- **Port 7777**: **Jolokia** (JMX over HTTP/REST - JSON format)
- **Port 7778**: **Prometheus JMX Exporter** (Prometheus metrics format)

## Configuration

### 1. Create JMX Credentials Secret

```bash
kubectl apply -f kafka-jmx-credentials.yaml
```

This creates authentication credentials for Jolokia access control.

### 2. Deploy Kafka with Metrics Enabled

The `kafka-core.yaml` includes:

```yaml
spec:
  metrics:
    authentication:
      type: mtls                    # mTLS for metrics endpoints
    jolokia:
      accessControl:
        enabled: true
        secretRef: jmx-credentials  # Reference to credentials
    prometheus:
      whitelist:
      - "kafka.server:*"
      - "kafka.network:*"
      - "kafka.controller:*"
      - "kafka.log:*"
      - "java.lang:*"
```

```bash
kubectl apply -f kafka-core.yaml
```

## Accessing Metrics

### Jolokia (Port 7777)

Access JMX metrics via HTTP/JSON:

```bash
# Port-forward to a broker
kubectl port-forward -n confluent kafka-0 7777:7777

# Get all MBean names
curl http://localhost:7777/jolokia/list | jq .

# Get specific metric (example: messages in per second)
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec | jq .

# Get broker topic metrics
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=* | jq .
```

**Authentication:**
- Username: `admin` or `monitorRole`
- Password: `admin-secret` or `monitor-secret`
- Access levels: `readwrite` (admin) or `readonly` (monitorRole)

```bash
# With authentication
curl -u admin:admin-secret http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec
```

### Prometheus Exporter (Port 7778)

Access Prometheus-formatted metrics:

```bash
# Port-forward to a broker
kubectl port-forward -n confluent kafka-0 7778:7778

# Get all Prometheus metrics
curl http://localhost:7778/metrics | head -50

# Get specific metrics (grep)
curl http://localhost:7778/metrics | grep kafka_server_brokertopicmetrics
```

## Prometheus Integration

### Option 1: ServiceMonitor (Recommended)

If using Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-metrics
  namespace: confluent
  labels:
    app: kafka
spec:
  selector:
    matchLabels:
      app: kafka
      platform.confluent.io/type: kafka
  endpoints:
  - port: prometheus
    interval: 30s
    path: /metrics
```

### Option 2: Prometheus Scrape Config

Add to Prometheus configuration:

```yaml
scrape_configs:
- job_name: 'kafka-jmx'
  scrape_interval: 30s
  static_configs:
  - targets:
    - kafka-0.kafka.confluent.svc.cluster.local:7778
    - kafka-1.kafka.confluent.svc.cluster.local:7778
    # ... add all 12 brokers
```

### Option 3: Helm Install with Scrape Config

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values - <<EOF
prometheus:
  prometheusSpec:
    additionalScrapeConfigs:
    - job_name: 'kafka-prometheus'
      scrape_interval: 30s
      static_configs:
      - targets:
        - kafka-0.kafka.confluent.svc.cluster.local:7778
        - kafka-1.kafka.confluent.svc.cluster.local:7778
        - kafka-2.kafka.confluent.svc.cluster.local:7778
        - kafka-3.kafka.confluent.svc.cluster.local:7778
        - kafka-4.kafka.confluent.svc.cluster.local:7778
        - kafka-5.kafka.confluent.svc.cluster.local:7778
        - kafka-6.kafka.confluent.svc.cluster.local:7778
        - kafka-7.kafka.confluent.svc.cluster.local:7778
        - kafka-8.kafka.confluent.svc.cluster.local:7778
        - kafka-9.kafka.confluent.svc.cluster.local:7778
        - kafka-10.kafka.confluent.svc.cluster.local:7778
        - kafka-11.kafka.confluent.svc.cluster.local:7778
grafana:
  adminPassword: admin
EOF
```

## Key Metrics to Monitor

### Throughput
```
kafka_server_brokertopicmetrics_messagesinpersec_count
kafka_server_brokertopicmetrics_bytesinpersec_count
kafka_server_brokertopicmetrics_bytesoutpersec_count
```

### Replication
```
kafka_server_replicamanager_underreplicatedpartitions
kafka_server_replicamanager_partitioncount
kafka_server_replicamanager_leadercount
```

### Request Latency
```
kafka_network_requestmetrics_totaltimems
kafka_network_requestmetrics_requestqueuetimems
```

### Broker Health
```
kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent_oneminuterate
```

### JVM/GC
```
java_lang_memory_heapmemoryusage_used
java_lang_garbagecollector_collectioncount
java_lang_garbagecollector_collectiontime
```

## Grafana Dashboards

Import Confluent's official Kafka dashboards:

1. Download from: https://github.com/confluentinc/jmx-monitoring-stacks/tree/main/grafana-dashboards
2. In Grafana: **+** → **Import** → Upload JSON

Or use dashboard IDs:
- Kafka Overview: ID TBD
- Kafka Topics: ID TBD

## Troubleshooting

### Check if metrics are exposed

```bash
# Check Jolokia endpoint
kubectl exec -n confluent kafka-0 -- curl localhost:7777/jolokia/version

# Check Prometheus endpoint
kubectl exec -n confluent kafka-0 -- curl localhost:7778/metrics | head
```

### Verify JMX credentials

```bash
# Check secret exists
kubectl get secret jmx-credentials -n confluent

# Check secret contents
kubectl get secret jmx-credentials -n confluent -o jsonpath='{.data.jmxremote\.password}' | base64 -d
kubectl get secret jmx-credentials -n confluent -o jsonpath='{.data.jmxremote\.access}' | base64 -d
```

### Test Jolokia authentication

```bash
kubectl port-forward -n confluent kafka-0 7777:7777

# Should fail without auth
curl http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec

# Should work with auth
curl -u admin:admin-secret http://localhost:7777/jolokia/read/kafka.server:type=BrokerTopicMetrics,name=MessagesInPerSec
```

## Security Notes

- **JMX credentials**: username/password in `jmx-credentials` secret
- **mTLS**: Metrics endpoints use mTLS for transport security
- **Access control**: `admin` has `readwrite`, `monitorRole` has `readonly`
- **Production**: Change default passwords in `kafka-jmx-credentials.yaml`

## Cost Impact

**No additional cost** - JMX/Jolokia/Prometheus are built into CFK.

If deploying Prometheus/Grafana:
- Prometheus: ~$30/month (t3.medium)
- Grafana: ~$15/month (t3.small)
- **Total: ~$45/month**

## References

- [Official CFK Monitoring Docs](https://docs.confluent.io/operator/current/co-monitor-cp.html)
- [Jolokia Documentation](https://jolokia.org/reference/html/)
- [JMX Monitoring Stacks](https://github.com/confluentinc/jmx-monitoring-stacks)
