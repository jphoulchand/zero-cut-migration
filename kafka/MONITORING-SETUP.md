# Kafka JMX Monitoring with Prometheus & Grafana

This guide shows how to enable JMX metrics export from Kafka brokers and set up Prometheus/Grafana for monitoring.

## Architecture

```
Kafka Brokers (with javaagent)
    ↓ JMX metrics on port 9091
Prometheus (in EKS)
    ↓ scrapes metrics
Grafana (in EKS)
    ↓ SSH tunnel
Local Browser
```

## Prerequisites

- Kafka cluster deployed with CFK operator
- kubectl configured to access the EKS cluster
- Jumpbox with SSH access configured

## Step 1: Deploy JMX Configuration

The JMX exporter configuration uses the official Confluent monitoring stack config:

```bash
# Deploy the JMX exporter ConfigMap
kubectl apply -f kafka-jmx-config.yaml
```

This creates:
- `kafka-jmx-config` ConfigMap: Official Confluent JMX exporter rules
- `kafka-jmx-metrics` Service: Headless service for Prometheus scraping

## Step 2: Update Kafka Brokers with JMX Monitoring

The `kafka-core.yaml` has been updated with:

1. **Init container** to download the JMX exporter javaagent JAR from Maven Central
2. **Javaagent** configuration to load the JMX exporter on port 9091
3. **Volume mounts** for the JAR and configuration files

Deploy the updated Kafka configuration:

```bash
# If Kafka is already running, you'll need to perform a rolling update
kubectl apply -f kafka-core.yaml

# Watch the rolling restart
kubectl get pods -n confluent -w
```

### What Changed

The kafka-core.yaml now includes:

```yaml
# Init container downloads JMX exporter JAR
initContainers:
- name: download-jmx-exporter
  image: busybox:1.36
  command: [sh, -c, "wget -O /opt/jmx-exporter/jmx_prometheus_javaagent.jar ..."]

# JVM args load the javaagent
configOverrides:
  jvm:
  - "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=9091:/etc/jmx-exporter/config.yaml"
  - "-Dcom.sun.management.jmxremote=true"
  ...
```

## Step 3: Verify JMX Metrics Export

Check that the metrics endpoint is working:

```bash
# Get a Kafka broker pod name
KAFKA_POD=$(kubectl get pods -n confluent -l app=kafka -o jsonpath='{.items[0].metadata.name}')

# Port-forward to the JMX metrics port
kubectl port-forward -n confluent $KAFKA_POD 9091:9091

# In another terminal, test the metrics endpoint
curl http://localhost:9091/metrics | head -20
```

You should see Prometheus-formatted metrics like:
```
# HELP kafka_server_brokertopicmetrics_messagesinpersec_count_alltopics ...
# TYPE kafka_server_brokertopicmetrics_messagesinpersec_count_alltopics gauge
kafka_server_brokertopicmetrics_messagesinpersec_count_alltopics 1234.0
...
```

## Step 4: Deploy Prometheus & Grafana

We'll use the kube-prometheus-stack Helm chart:

```bash
# Add Prometheus community Helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create monitoring namespace
kubectl create namespace monitoring

# Install kube-prometheus-stack
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set grafana.adminPassword='admin' \
  --values - <<EOF
prometheus:
  prometheusSpec:
    podMonitorSelectorNilUsesHelmValues: false
    serviceMonitorSelectorNilUsesHelmValues: false
    additionalScrapeConfigs:
    - job_name: 'kafka-jmx'
      scrape_interval: 30s
      scrape_timeout: 10s
      static_configs:
      - targets:
        # Replace with actual Kafka pod IPs or use DNS (kafka-0.kafka.confluent.svc.cluster.local:9091)
        - kafka-0.kafka.confluent.svc.cluster.local:9091
        - kafka-1.kafka.confluent.svc.cluster.local:9091
        - kafka-2.kafka.confluent.svc.cluster.local:9091
        - kafka-3.kafka.confluent.svc.cluster.local:9091
        - kafka-4.kafka.confluent.svc.cluster.local:9091
        - kafka-5.kafka.confluent.svc.cluster.local:9091
        - kafka-6.kafka.confluent.svc.cluster.local:9091
        - kafka-7.kafka.confluent.svc.cluster.local:9091
        - kafka-8.kafka.confluent.svc.cluster.local:9091
        - kafka-9.kafka.confluent.svc.cluster.local:9091
        - kafka-10.kafka.confluent.svc.cluster.local:9091
        - kafka-11.kafka.confluent.svc.cluster.local:9091
grafana:
  adminPassword: admin
  service:
    type: ClusterIP
    port: 80
EOF
```

**Note**: The scrape config above uses static targets. For production, use a ServiceMonitor instead:

```yaml
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kafka-jmx-metrics
  namespace: confluent
  labels:
    app: kafka
spec:
  selector:
    matchLabels:
      app: kafka
      monitoring: prometheus
  endpoints:
  - port: jmx-metrics
    interval: 30s
    path: /metrics
EOF
```

## Step 5: Access Grafana via SSH Tunnel

Since Grafana is running in the EKS cluster, access it through the jumpbox:

```bash
# From your local machine

# Step 1: SSH tunnel to jumpbox with port forwarding
ssh -i ~/.ssh/your-key.pem -L 3000:localhost:3000 ec2-user@<jumpbox-ip>

# Step 2: On the jumpbox, port-forward to Grafana
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Now open http://localhost:3000 in your browser.

**Login credentials:**
- Username: `admin`
- Password: `admin` (change this immediately)

## Step 6: Import Confluent Kafka Dashboards

Confluent provides official Grafana dashboards. Import them:

1. In Grafana, click **"+"** → **Import**
2. Use these dashboard IDs or JSON files:
   - **Kafka Overview**: https://github.com/confluentinc/jmx-monitoring-stacks/tree/main/grafana-dashboards

Or download the official dashboards:

```bash
# Download Confluent's official Kafka dashboards
wget https://raw.githubusercontent.com/confluentinc/jmx-monitoring-stacks/main/grafana-dashboards/kafka-overview.json
```

Then import via **Upload JSON file** in Grafana.

## Alternative: Simpler SSH Tunnel (One Command)

Instead of the two-step SSH tunnel, use this one-liner:

```bash
# From your local machine, replace <jumpbox-ip> with actual IP
ssh -i ~/.ssh/your-key.pem -L 3000:$(kubectl get svc -n monitoring kube-prometheus-stack-grafana -o jsonpath='{.spec.clusterIP}'):80 ec2-user@<jumpbox-ip>
```

But this requires kubectl to be configured on the jumpbox, which is already the case.

## Key Metrics to Monitor

### Broker Health
- `kafka_server_kafkarequesthandlerpool_requesthandleravgidlepercent_oneminuterate`
  - Should be > 0.2 (20% idle)
  
### Throughput
- `kafka_server_brokertopicmetrics_messagesinpersec_count_alltopics`
- `kafka_server_brokertopicmetrics_bytesinpersec_count_alltopics`
- `kafka_server_brokertopicmetrics_bytesoutpersec_count_alltopics`

### Replication
- `kafka_server_replicamanager_underreplicatedpartitions`
  - Should be 0
- `kafka_server_replicamanager_partitioncount`
- `kafka_server_replicamanager_leadercount`

### Request Latencies
- `kafka_network_requestmetrics_totaltimems` (by request type)
- `kafka_network_requestmetrics_requestqueuetimems`

### KRaft Specific
- `kafka_server_raft_metrics_*` (controller metrics)

## Troubleshooting

### Metrics not showing in Prometheus

1. **Check JMX exporter is running:**
   ```bash
   kubectl exec -n confluent kafka-0 -- ps aux | grep javaagent
   ```
   You should see: `-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=9091:...`

2. **Check metrics endpoint directly:**
   ```bash
   kubectl exec -n confluent kafka-0 -- wget -O- localhost:9091/metrics | head
   ```

3. **Check Prometheus targets:**
   - SSH tunnel to Prometheus: `kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090`
   - Open http://localhost:9090/targets
   - Look for the `kafka-jmx` job

### Init container fails to download JAR

If the init container can't download from Maven Central:

1. **Manual approach** - build a custom image with the JAR pre-loaded:
   ```dockerfile
   FROM confluentinc/cp-server:8.2.1
   USER root
   RUN wget -O /opt/jmx-exporter/jmx_prometheus_javaagent.jar \
       https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.1.0/jmx_prometheus_javaagent-1.1.0.jar
   USER appuser
   ```

2. **Or upload to S3 and download from there:**
   ```bash
   # Upload to S3
   aws s3 cp jmx_prometheus_javaagent-1.1.0.jar s3://your-bucket/

   # Update init container to download from S3
   aws s3 cp s3://your-bucket/jmx_prometheus_javaagent-1.1.0.jar /opt/jmx-exporter/
   ```

### High memory usage from JMX exporter

If the JMX exporter consumes too much memory, tune the javaagent heap:

```yaml
jvm:
- "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=9091:/etc/jmx-exporter/config.yaml"
- "-XX:MaxRAMPercentage=1.0"  # Limit javaagent to 1% of container memory
```

## Cost Impact

Adding JMX monitoring has minimal cost impact:

- **Prometheus**: ~2GB memory, ~1 CPU = ~$30/month on t3.medium
- **Grafana**: ~512MB memory, ~0.5 CPU = ~$15/month on t3.small
- **Storage**: ~20GB for 15-day retention = ~$2/month EBS

**Total additional cost: ~$47/month**

## Cost Management for Testing

If you're testing and want to save costs overnight without full teardown:

### Scale Down (Pause Kafka, Keep Configuration)

```bash
# Scale Kafka brokers to 0 replicas
kubectl scale kafka kafka --replicas=0 -n confluent

# Scale KRaft controllers to 0 replicas
kubectl scale kraftcontroller kraftcontroller --replicas=0 -n confluent

# Optional: Scale Schema Registry and Connect if deployed
kubectl scale schemaregistry schemaregistry --replicas=0 -n confluent
kubectl scale connect connect --replicas=0 -n confluent
```

**What happens:**
- All Kafka pods terminate
- Karpenter automatically terminates the spot instances (~5-10 minutes)
- EBS volumes persist (data is NOT lost)
- Cost drops from ~$511/month to ~$193/month (EKS + system nodes only)

**Savings:** ~$318/month or ~$10/day

### Scale Up (Resume Kafka)

```bash
# Restore Kafka brokers
kubectl scale kafka kafka --replicas=12 -n confluent

# Restore KRaft controllers
kubectl scale kraftcontroller kraftcontroller --replicas=5 -n confluent

# Optional: Restore Schema Registry and Connect
kubectl scale schemaregistry schemaregistry --replicas=2 -n confluent
kubectl scale connect connect --replicas=2 -n confluent

# Watch pods come back online
kubectl get pods -n confluent -w
```

**Recovery time:** ~5-10 minutes (Karpenter provisions instances, pods start)

### Complete Cleanup

When finished testing, delete all resources:

```bash
# Delete Kafka resources
kubectl delete -f kafka-core.yaml
kubectl delete -f kafka-auxiliary.yaml  # if deployed
kubectl delete -f kafka-jmx-config.yaml
kubectl delete -f kafka-rbac.yaml

# Delete monitoring (if deployed)
helm uninstall kube-prometheus-stack -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring

# Delete Confluent operator
helm uninstall confluent-operator -n confluent
kubectl delete namespace confluent

# Destroy AWS infrastructure (from project root)
cd ../tf
terraform destroy -auto-approve
```

**Note:** `terraform destroy` removes:
- EKS cluster and all nodes
- VPCs, subnets, route tables
- EBS volumes (Kafka data will be lost)
- VPC endpoints
- Jumpbox and Elastic IP
- All AWS resources created by Terraform

## Next Steps

- Set up alerting rules in Prometheus
- Configure Grafana alerts to Slack/PagerDuty
- Add recording rules for expensive queries
- Set up long-term storage (Thanos/Cortex) for >15 day retention
