# Kafka mTLS Deployment Guide

## Overview

This guide covers deploying a 12-broker Kafka cluster with mutual TLS (mTLS) authentication for inter-broker communication using self-signed certificates.

**Architecture:**
- **Kafka Cluster:** 12 brokers across 3 availability zones (4 brokers per AZ)
- **KRaft Controllers:** 5 controllers for metadata management (no ZooKeeper)
- **Security:** TLS 1.3 encryption + mTLS authentication for inter-broker communication
- **Certificates:** Self-signed CA with per-broker certificates (10-year validity)
- **Additional Components:** Schema Registry, Kafka Connect (both with mTLS to Kafka)

---

## Prerequisites

### Timing

**IMPORTANT:** Deploy Kafka mTLS **AFTER** the Kubernetes 1.34 upgrade completes.

Current status (2026-05-23):
- ✅ Terraform infrastructure deployed
- 🔄 Kubernetes upgrade 1.33 → 1.34 in progress (50% complete)
- ⏳ Kafka mTLS deployment pending upgrade completion

### Required Tools

All tools are pre-installed on the jumpbox via `/tf/scripts/install_binaries.sh`:

- ✅ `openssl` - Certificate generation
- ✅ `keytool` - JKS keystore management (from OpenJDK)
- ✅ `kubectl` - Kubernetes cluster access
- ✅ Kafka CLI tools - Verification and testing

### Cluster Requirements

- ✅ EKS cluster running Kubernetes 1.34+
- ✅ Confluent for Kubernetes Operator v3.1.1 installed
- ✅ `confluent` namespace created
- ✅ Karpenter nodepools configured with ARM64 instances
- ✅ 100Gi gp3 storage class available

---

## Deployment Process

### Stage 1: Generate Certificates

**Location:** Run from jumpbox at `/home/ec2-user/kafka/certs/`

```bash
# SSH to jumpbox
ssh -i ~/.ssh/your-key.pem ec2-user@<jumpbox-ip>

# Create certificate directory
mkdir -p ~/kafka/certs
cd ~/kafka/certs

# Copy certificate generation script
# (Upload generate-kafka-certs.sh to jumpbox)
scp -i ~/.ssh/your-key.pem kafka/certs/generate-kafka-certs.sh ec2-user@<jumpbox-ip>:~/kafka/certs/

# Make executable
chmod +x generate-kafka-certs.sh

# Run certificate generation
./generate-kafka-certs.sh
```

**Expected Output:**

```
╔══════════════════════════════════════════════════════════════╗
║    Kafka Self-Signed Certificate Generation Script         ║
╚══════════════════════════════════════════════════════════════╝

[1/6] Generating Root CA...
✓ Root CA generated

[2/6] Creating truststore...
✓ Truststore created: ca/kafka.truststore.jks

[3/6] Generating broker certificates (0 to 11)...
  Generating certificate for: kafka-0.kafka.confluent.svc.cluster.local
  Generating certificate for: kafka-1.kafka.confluent.svc.cluster.local
  ...
  Generating certificate for: kafka-11.kafka.confluent.svc.cluster.local
✓ Generated certificates for 12 brokers

[4/6] Creating Kubernetes secret YAML files...
✓ Kubernetes secrets created

[5/6] Creating certificate summary...
[Full certificate info displayed]

[6/6] Creating client configuration sample...

╔══════════════════════════════════════════════════════════════╗
║              Certificate Generation Complete!                ║
╚══════════════════════════════════════════════════════════════╝
```

**Generated Files:**

```
generated-certs/
├── ca/
│   ├── ca-key.pem               # Root CA private key (PROTECT THIS)
│   ├── ca-cert.pem              # Root CA certificate
│   └── kafka.truststore.jks     # JKS truststore
├── brokers/kafka-{0..11}/
│   ├── server-key.pem           # Broker private key
│   ├── server-cert.pem          # Broker certificate (signed by CA)
│   ├── kafka.keystore.jks       # JKS keystore
│   └── keystore-info.txt        # Verification details
├── secrets/
│   ├── apply-secrets.yaml       # ← DEPLOY THIS
│   ├── kafka-tls-secret.yaml
│   └── kafka-ca-secret.yaml
└── CERTIFICATE-INFO.txt         # Summary and passwords
```

**Passwords (stored in secrets):**
- Keystore: `confluentkeystorepass`
- Truststore: `confluenttruststorepass`
- Key: `confluentkeypass`

---

### Stage 2: Deploy Kubernetes Secrets

**Apply the generated secrets to the `confluent` namespace:**

```bash
cd ~/kafka/certs/generated-certs

# Verify namespace exists
kubectl get namespace confluent
# If not exists: kubectl create namespace confluent

# Apply secrets
kubectl apply -f secrets/apply-secrets.yaml

# Verify secrets created
kubectl get secrets -n confluent | grep kafka
```

**Expected Output:**

```
kafka-ca-pair   Opaque   2      10s
kafka-tls       Opaque   5      10s
```

**Verify secret contents:**

```bash
# Check kafka-tls secret
kubectl describe secret kafka-tls -n confluent

# Should show:
# Data
# ====
# keystore.jks:          <keystore-size> bytes
# truststore.jks:        <truststore-size> bytes
# keystore-password:     <password-length> bytes
# truststore-password:   <password-length> bytes
# key-password:          <password-length> bytes
```

---

### Stage 3: Deploy Kafka with mTLS

**Upload and apply the Kafka CRD configuration:**

```bash
# Upload kafka-mtls.yaml to jumpbox
scp -i ~/.ssh/your-key.pem kafka/kafka-mtls.yaml ec2-user@<jumpbox-ip>:~/kafka/

# Apply Kafka CRD
cd ~/kafka
kubectl apply -f kafka-mtls.yaml
```

**Expected Resources Created:**

```
kafka.platform.confluent.io/kafka created
kraftcontroller.platform.confluent.io/kraft-controller created
schemaregistry.platform.confluent.io/schemaregistry created
connect.platform.confluent.io/connect created
```

**Monitor Deployment:**

```bash
# Watch KRaft controllers come up (5 replicas)
kubectl get pods -n confluent -l app=kraft-controller -w

# Expected progression:
# kraft-controller-0   0/1   Pending      0s
# kraft-controller-0   0/1   Init:0/1     5s
# kraft-controller-0   1/1   Running      30s
# kraft-controller-1   1/1   Running      45s
# ...
# kraft-controller-4   1/1   Running      2m

# Watch Kafka brokers come up (12 replicas)
kubectl get pods -n confluent -l app=kafka -w

# Expected timeline:
# - Controllers: ~5 minutes (must complete first)
# - Brokers: ~10 minutes (4 per AZ, rolling deployment)
# - Schema Registry: ~3 minutes (3 replicas)
# - Connect: ~3 minutes (2 replicas)
# Total: ~20-25 minutes for full deployment
```

---

## Verification

### Certificate Verification

**Check TLS certificates are loaded:**

```bash
# View broker 0 logs for SSL initialization
kubectl logs -n confluent kafka-0 | grep -i ssl

# Should show:
# [2026-05-23 ...] INFO Registered broker 0 at path /brokers/ids/0 with security.protocol=SSL
# [2026-05-23 ...] INFO Successfully loaded SSL keystore
# [2026-05-23 ...] INFO Successfully loaded SSL truststore
# [2026-05-23 ...] INFO SSL handshake completed for connection from /10.19.x.x
```

**Verify certificate details:**

```bash
# Extract keystore from secret
kubectl get secret kafka-tls -n confluent -o jsonpath='{.data.keystore\.jks}' | base64 -d > /tmp/kafka.keystore.jks

# List keystore contents
keytool -list -v -keystore /tmp/kafka.keystore.jks -storepass confluentkeystorepass

# Should show:
# Alias name: kafka-0.kafka.confluent.svc.cluster.local
# Entry type: PrivateKeyEntry
# Certificate chain length: 1
# Certificate[1]:
# Owner: CN=kafka-0.kafka.confluent.svc.cluster.local, OU=Engineering, O=Confluent, L=MountainView, ST=CA, C=US
# Issuer: CN=Kafka-CA, OU=Engineering, O=Confluent, L=MountainView, ST=CA, C=US
# Valid from: ... until: ... (10 years)
```

---

### Inter-Broker mTLS Verification

**Test SSL handshake between brokers:**

```bash
# Exec into broker-0
kubectl exec -it kafka-0 -n confluent -- bash

# Inside the pod, test SSL connection to broker-1
openssl s_client -connect kafka-1.kafka.confluent.svc.cluster.local:9092 \
  -CAfile /mnt/sslcerts/truststore.jks \
  -cert /mnt/sslcerts/keystore.jks

# Expected output:
# SSL handshake has read 1234 bytes and written 5678 bytes
# ---
# New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
# Server public key is 2048 bit
# SSL-Session:
#     Protocol  : TLSv1.3
#     Cipher    : TLS_AES_256_GCM_SHA384
# ---
# Verify return code: 0 (ok)
```

**Check broker metrics for SSL connections:**

```bash
# View SSL handshake metrics
kubectl exec -it kafka-0 -n confluent -- \
  kafka-run-class kafka.tools.JmxTool \
    --object-name kafka.server:type=BrokerTopicMetrics,name=SslHandshakeCount \
    --one-time true

# Should show non-zero count for successful SSL handshakes
```

---

### Kafka Cluster Health Verification

**Check cluster metadata:**

```bash
# From jumpbox, list all brokers
kafka-broker-api-versions \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --command-config ~/kafka/client-ssl.properties

# Should show all 12 brokers:
# kafka-0.kafka.confluent.svc.cluster.local:9092 (id: 0 rack: eu-west-1a)
# kafka-1.kafka.confluent.svc.cluster.local:9092 (id: 1 rack: eu-west-1b)
# kafka-2.kafka.confluent.svc.cluster.local:9092 (id: 2 rack: eu-west-1c)
# ...
# kafka-11.kafka.confluent.svc.cluster.local:9092 (id: 11 rack: eu-west-1c)
```

**Create test topic and verify replication:**

```bash
# Create topic with RF=3 (replication factor 3)
kafka-topics \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --command-config ~/kafka/client-ssl.properties \
  --create \
  --topic test-mtls \
  --partitions 12 \
  --replication-factor 3

# Verify topic created
kafka-topics \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --command-config ~/kafka/client-ssl.properties \
  --describe \
  --topic test-mtls

# Expected output:
# Topic: test-mtls  PartitionCount: 12  ReplicationFactor: 3
# Topic: test-mtls  Partition: 0  Leader: 5  Replicas: 5,7,2  Isr: 5,7,2
# ...
# All partitions should show 3 replicas in ISR (In-Sync Replicas)
```

**Produce and consume messages:**

```bash
# Produce test messages
echo "test message 1" | kafka-console-producer \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --producer.config ~/kafka/client-ssl.properties \
  --topic test-mtls

# Consume messages
kafka-console-consumer \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --consumer.config ~/kafka/client-ssl.properties \
  --topic test-mtls \
  --from-beginning \
  --max-messages 1

# Should print: test message 1
```

---

### Schema Registry Verification

**Check Schema Registry connectivity to Kafka:**

```bash
# Check Schema Registry logs
kubectl logs -n confluent schemaregistry-0 | grep -i "kafka\|ssl"

# Should show:
# [2026-05-23 ...] INFO Successfully connected to Kafka cluster via SSL
# [2026-05-23 ...] INFO Using security.protocol=SSL

# Test Schema Registry API
curl -k https://schemaregistry.confluent.svc.cluster.local:8081/subjects

# Expected: [] (empty array, no schemas yet)
```

---

### Connect Verification

**Check Kafka Connect connectivity:**

```bash
# Check Connect logs
kubectl logs -n confluent connect-0 | grep -i "kafka\|ssl"

# List connectors
curl -k https://connect.confluent.svc.cluster.local:8083/connectors

# Expected: [] (no connectors deployed yet)
```

---

## Client Configuration

### SSL Properties for Kafka Clients

All Kafka clients connecting to the cluster must use SSL configuration.

**Client SSL Properties (`~/kafka/client-ssl.properties`):**

```properties
# Security protocol
security.protocol=SSL

# Truststore configuration (to trust Kafka brokers)
ssl.truststore.location=/home/ec2-user/kafka/certs/generated-certs/ca/kafka.truststore.jks
ssl.truststore.password=confluenttruststorepass

# Keystore configuration (for client authentication - mTLS)
# Only required if brokers enforce client certificate authentication
# For internal listener with mTLS: required
# For external listener with SASL/PLAIN: not required
#ssl.keystore.location=/home/ec2-user/kafka/client-keystore.jks
#ssl.keystore.password=confluentkeystorepass
#ssl.key.password=confluentkeypass

# SSL endpoint identification (hostname verification)
ssl.endpoint.identification.algorithm=https
```

**Producer Example:**

```bash
kafka-console-producer \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --producer.config ~/kafka/client-ssl.properties \
  --topic my-topic
```

**Consumer Example:**

```bash
kafka-console-consumer \
  --bootstrap-server kafka.confluent.svc.cluster.local:9092 \
  --consumer.config ~/kafka/client-ssl.properties \
  --topic my-topic \
  --from-beginning
```

---

### Application Client Configuration

**Java Application (Spring Boot):**

```yaml
# application.yml
spring:
  kafka:
    bootstrap-servers: kafka.confluent.svc.cluster.local:9092
    security:
      protocol: SSL
    ssl:
      trust-store-location: file:/path/to/kafka.truststore.jks
      trust-store-password: confluenttruststorepass
      trust-store-type: JKS
      # For mTLS client authentication:
      # key-store-location: file:/path/to/client.keystore.jks
      # key-store-password: confluentkeystorepass
      # key-store-type: JKS
```

**Python Application (confluent-kafka):**

```python
from confluent_kafka import Producer, Consumer

# Producer configuration
producer_config = {
    'bootstrap.servers': 'kafka.confluent.svc.cluster.local:9092',
    'security.protocol': 'SSL',
    'ssl.ca.location': '/path/to/ca-cert.pem',
    # For mTLS:
    # 'ssl.certificate.location': '/path/to/client-cert.pem',
    # 'ssl.key.location': '/path/to/client-key.pem',
}

producer = Producer(producer_config)

# Consumer configuration
consumer_config = {
    'bootstrap.servers': 'kafka.confluent.svc.cluster.local:9092',
    'group.id': 'my-group',
    'security.protocol': 'SSL',
    'ssl.ca.location': '/path/to/ca-cert.pem',
}

consumer = Consumer(consumer_config)
```

---

## Troubleshooting

### Issue 1: Brokers Not Starting - SSL Initialization Failed

**Symptoms:**

```bash
kubectl logs kafka-0 -n confluent | tail

# Error:
# [2026-05-23 ...] ERROR Failed to load SSL keystore
# java.security.KeyStoreException: keystore password was incorrect
```

**Cause:** Incorrect keystore password in secret

**Fix:**

```bash
# Verify secret password
kubectl get secret kafka-tls -n confluent -o jsonpath='{.data.keystore-password}' | base64 -d
# Should output: confluentkeystorepass

# If incorrect, regenerate certificates and secrets:
cd ~/kafka/certs
./generate-kafka-certs.sh
kubectl apply -f generated-certs/secrets/apply-secrets.yaml

# Restart brokers
kubectl rollout restart statefulset kafka -n confluent
```

---

### Issue 2: Inter-Broker Communication Failing - Certificate Trust Issues

**Symptoms:**

```bash
kubectl logs kafka-0 -n confluent | grep -i trust

# Error:
# [2026-05-23 ...] ERROR [ReplicaFetcherThread-0-1] Error in fetch kafka.server.ReplicaFetcherThread
# javax.net.ssl.SSLHandshakeException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
```

**Cause:** Broker certificate not signed by CA in truststore

**Fix:**

```bash
# Verify CA certificate in truststore matches signer
kubectl get secret kafka-tls -n confluent -o jsonpath='{.data.truststore\.jks}' | base64 -d > /tmp/truststore.jks

keytool -list -v -keystore /tmp/truststore.jks -storepass confluenttruststorepass

# Check "Owner" matches the CA that signed broker certificates
# Should show: CN=Kafka-CA, OU=Engineering, O=Confluent, L=MountainView, ST=CA, C=US

# If mismatch, regenerate certificates (ensure generate-kafka-certs.sh completed successfully)
```

---

### Issue 3: External Listener Not Accessible from Jumpbox

**Symptoms:**

```bash
# From jumpbox
kafka-broker-api-versions --bootstrap-server kafka.confluent.svc.cluster.local:9092

# Error:
# Connection to node -1 (kafka.confluent.svc.cluster.local/10.19.x.x:9092) could not be established. Broker may not be available.
```

**Cause:** DNS resolution failing (NLB not configured yet)

**Fix:**

```bash
# Check NLB DNS is configured
resolvectl status

# Should show kube-dns-external NLB hostname as nameserver
# If not, check jumpbox user_data was applied:
sudo cat /etc/systemd/resolved.conf.d/kube-dns.conf

# If missing, manually configure:
sudo tee /etc/systemd/resolved.conf.d/kube-dns.conf > /dev/null <<EOF
[Resolve]
DNS=<nlb-dns-hostname>
Domains=confluent.svc.cluster.local svc.cluster.local cluster.local
EOF

sudo systemctl restart systemd-resolved

# Verify DNS resolution
dig kafka.confluent.svc.cluster.local +short
# Should return pod IPs
```

---

### Issue 4: Schema Registry Cannot Connect to Kafka

**Symptoms:**

```bash
kubectl logs schemaregistry-0 -n confluent | grep ERROR

# Error:
# [2026-05-23 ...] ERROR Failed to connect to Kafka cluster
# org.apache.kafka.common.errors.SslAuthenticationException: SSL handshake failed
```

**Cause:** Schema Registry missing client certificates for mTLS

**Fix:**

Verify Schema Registry Kafka dependency configuration in `kafka-mtls.yaml`:

```yaml
dependencies:
  kafka:
    bootstrapEndpoint: kafka.confluent.svc.cluster.local:9092
    tls:
      enabled: true
      secretRef: kafka-tls  # Must match secret name
    authentication:
      type: mtls
      principalMappingRules:
      - "RULE:^CN=(.*?),OU=Engineering,O=Confluent,L=MountainView,ST=CA,C=US$/$1/"
      - "DEFAULT"
```

Ensure secret `kafka-tls` exists and contains both keystore and truststore:

```bash
kubectl describe secret kafka-tls -n confluent
# Must show: keystore.jks, truststore.jks, passwords

# If missing, re-apply:
kubectl apply -f ~/kafka/certs/generated-certs/secrets/apply-secrets.yaml
kubectl rollout restart statefulset schemaregistry -n confluent
```

---

### Issue 5: Certificate Expiration Warning

**Symptoms:**

```bash
# Certificate expires in < 30 days warning
kubectl logs kafka-0 -n confluent | grep "certificate.*expir"
```

**Cause:** Approaching 10-year certificate expiration

**Fix:**

Rotate certificates before expiration:

```bash
# 1. Generate new certificates with fresh validity period
cd ~/kafka/certs
./generate-kafka-certs.sh

# 2. Apply new secrets
kubectl apply -f generated-certs/secrets/apply-secrets.yaml

# 3. Rolling restart of all components (zero-downtime)
kubectl rollout restart statefulset kafka -n confluent
kubectl rollout restart statefulset kraft-controller -n confluent
kubectl rollout restart statefulset schemaregistry -n confluent
kubectl rollout restart statefulset connect -n confluent

# 4. Verify all pods running with new certificates
kubectl get pods -n confluent
```

---

## Migration from Non-TLS Kafka

If you have an existing Kafka cluster **without TLS** and want to migrate to mTLS:

### Option 1: Blue-Green Deployment (Recommended)

1. Deploy new Kafka cluster with mTLS (use different cluster name: `kafka-mtls`)
2. Configure MirrorMaker 2 to replicate data from old to new cluster
3. Switch applications to new cluster
4. Decommission old cluster

**Pros:** Zero downtime, easy rollback  
**Cons:** Requires additional resources during migration

### Option 2: In-Place Upgrade (Advanced)

**⚠️ WARNING:** Requires cluster downtime

1. Enable TLS on listeners without requiring client certificates
2. Restart all brokers
3. Update clients to use SSL
4. Enable `ssl.client.auth=required` for mTLS
5. Restart all brokers again

**Not recommended for production** - use blue-green instead.

---

## Security Best Practices

### Certificate Management

1. **Protect CA Private Key:**
   ```bash
   # ca-key.pem can sign new certificates - store securely
   chmod 600 ~/kafka/certs/generated-certs/ca/ca-key.pem
   
   # Consider moving to secure vault after initial setup
   # AWS Secrets Manager example:
   aws secretsmanager create-secret \
     --name kafka-ca-private-key \
     --secret-binary fileb://~/kafka/certs/generated-certs/ca/ca-key.pem
   ```

2. **Rotate Certificates Regularly:**
   - Current validity: 10 years (3650 days)
   - Recommended rotation: Every 2-3 years
   - Set calendar reminder for 2029-05-23

3. **Audit Certificate Usage:**
   ```bash
   # List all certificates nearing expiration
   for i in {0..11}; do
     openssl x509 -in ~/kafka/certs/generated-certs/brokers/kafka-$i/server-cert.pem \
       -noout -enddate
   done
   ```

### Access Control

1. **Limit Namespace Access:**
   ```bash
   # Only authorized users should access confluent namespace
   kubectl create rolebinding kafka-admin \
     --clusterrole=admin \
     --user=your-email@example.com \
     --namespace=confluent
   ```

2. **Secret Encryption at Rest:**
   - EKS automatically encrypts secrets using AWS KMS
   - Verify encryption is enabled:
   ```bash
   aws eks describe-cluster \
     --name jph-demo-cluster \
     --region eu-west-1 \
     --query 'cluster.encryptionConfig'
   ```

3. **Network Policies:**
   ```yaml
   # Restrict traffic to Kafka pods
   apiVersion: networking.k8s.io/v1
   kind: NetworkPolicy
   metadata:
     name: kafka-network-policy
     namespace: confluent
   spec:
     podSelector:
       matchLabels:
         app: kafka
     policyTypes:
     - Ingress
     ingress:
     - from:
       - namespaceSelector:
           matchLabels:
             name: confluent
       ports:
       - protocol: TCP
         port: 9092
   ```

---

## Cost Considerations

### Additional Costs for mTLS

| Component | Monthly Cost | Notes |
|-----------|--------------|-------|
| TLS Processing Overhead | ~$0 | Included in existing broker resources |
| Certificate Storage (Secrets) | ~$0.01 | Negligible S3 cost |
| **Total Additional** | **~$0** | No significant cost increase |

**Performance Impact:**
- TLS encryption adds ~5-10ms latency per request
- CPU overhead: ~5-10% increase (already accounted for in resource limits)
- Negligible impact at normal throughput (<100k msgs/sec)

---

## Monitoring and Observability

### Key Metrics to Monitor

**SSL/TLS Metrics:**

```bash
# SSL handshake rate
kafka.network:type=SocketServer,name=NetworkProcessorAvgIdlePercent

# Failed SSL handshakes
kafka.server:type=BrokerTopicMetrics,name=FailedAuthenticationTotal

# SSL session creation rate
kafka.server:type=BrokerTopicMetrics,name=SslHandshakeCount
```

**Certificate Expiration:**

Set up alerts for certificates expiring in < 90 days:

```bash
# Check expiration date
kubectl exec -it kafka-0 -n confluent -- \
  openssl x509 -in /mnt/sslcerts/server-cert.pem -noout -enddate

# Expected: notAfter=May 20 12:34:56 2036 GMT (10 years)
```

---

## Reference

### File Locations

| File | Location | Purpose |
|------|----------|---------|
| Certificate generation script | `kafka/certs/generate-kafka-certs.sh` | Generate CA and broker certificates |
| Kafka mTLS CRD | `kafka/kafka-mtls.yaml` | Kafka cluster configuration |
| Generated certificates | `~/kafka/certs/generated-certs/` | CA, broker certs, keystores |
| Kubernetes secrets | `confluent` namespace | TLS secrets for Kafka |
| Client SSL config | `~/kafka/client-ssl.properties` | Client connection properties |

### Key Passwords

**⚠️ SENSITIVE - Stored in Kubernetes secrets**

| Password Type | Value | Usage |
|---------------|-------|-------|
| Keystore | `confluentkeystorepass` | JKS keystore password |
| Truststore | `confluenttruststorepass` | JKS truststore password |
| Key | `confluentkeypass` | Private key password |

### Certificate Details

| Component | Key Size | Validity | Algorithm |
|-----------|----------|----------|-----------|
| Root CA | 4096-bit RSA | 10 years | SHA256withRSA |
| Broker Certificates | 2048-bit RSA | 10 years | SHA256withRSA |
| TLS Protocol | - | TLS 1.3, 1.2 | - |
| Cipher Suites | - | AES-256-GCM, AES-128-GCM | - |

### Support Contacts

| Component | Documentation | Support |
|-----------|---------------|---------|
| Confluent for Kubernetes | https://docs.confluent.io/operator/current/ | Confluent Support Portal |
| Kafka Security | https://kafka.apache.org/documentation/#security | Apache Kafka Documentation |
| AWS EKS | https://docs.aws.amazon.com/eks/ | AWS Support |

---

## Appendix: Complete Deployment Checklist

### Pre-Deployment

- [ ] Kubernetes 1.34+ upgrade complete
- [ ] Confluent Operator v3.1.1 installed
- [ ] `confluent` namespace created
- [ ] Karpenter nodepools healthy (12 nodes available)
- [ ] Storage class `gp3` available

### Certificate Generation

- [ ] Run `generate-kafka-certs.sh`
- [ ] Verify 12 broker certificates generated
- [ ] Review `CERTIFICATE-INFO.txt`
- [ ] Backup `ca-key.pem` to secure location
- [ ] Record passwords from `CERTIFICATE-INFO.txt`

### Secret Deployment

- [ ] Apply `secrets/apply-secrets.yaml`
- [ ] Verify `kafka-tls` secret exists
- [ ] Verify `kafka-ca-pair` secret exists
- [ ] Check secret data contains keystore, truststore, passwords

### Kafka Deployment

- [ ] Apply `kafka-mtls.yaml`
- [ ] Wait for 5 KRaft controllers (Running)
- [ ] Wait for 12 Kafka brokers (Running)
- [ ] Wait for 3 Schema Registry instances (Running)
- [ ] Wait for 2 Connect instances (Running)
- [ ] Total wait time: ~20-25 minutes

### Verification

- [ ] Check broker logs for SSL initialization
- [ ] Test inter-broker mTLS handshake
- [ ] List all brokers via `kafka-broker-api-versions`
- [ ] Create test topic with RF=3
- [ ] Produce and consume test messages
- [ ] Verify Schema Registry connectivity
- [ ] Verify Kafka Connect connectivity

### Post-Deployment

- [ ] Configure client SSL properties
- [ ] Test application connectivity
- [ ] Set certificate rotation reminder (2029-05-23)
- [ ] Document deployment in runbook
- [ ] Clean up test topics

---

**Deployment Date:** 2026-05-23  
**Kafka Version:** Apache Kafka 3.x (via Confluent Platform)  
**Security:** TLS 1.3 + mTLS for inter-broker communication  
**Certificate Validity:** 10 years (expires 2036-05-20)
