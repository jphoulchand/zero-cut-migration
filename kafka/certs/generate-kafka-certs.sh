#!/bin/bash
# =============================================================================
# generate-kafka-certs.sh
#
# Generates self-signed certificates for Kafka cluster with mTLS
# - Root CA certificate
# - Server certificates for each Kafka broker
# - Keystores and truststores in JKS format
# - Kubernetes secrets ready to deploy
#
# Usage:
#   ./generate-kafka-certs.sh
#
# Prerequisites:
#   - openssl
#   - keytool (from JDK)
#   - kubectl (configured for your cluster)
# =============================================================================

set -euo pipefail

# Configuration
NAMESPACE="confluent"
CERT_DIR="./generated-certs"
VALIDITY_DAYS=3650  # 10 years
KEYSTORE_PASSWORD="confluentkeystorepass"
TRUSTSTORE_PASSWORD="confluenttruststorepass"
KEY_PASSWORD="confluentkeypass"

# Kafka cluster configuration
CLUSTER_NAME="kafka"
NUM_BROKERS=12  # Adjust based on your deployment
DOMAIN="confluent.svc.cluster.local"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Kafka Self-Signed Certificate Generation Script         ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

# Clean and create directories
rm -rf "$CERT_DIR"
mkdir -p "$CERT_DIR"/{ca,brokers,secrets}

cd "$CERT_DIR"

# =============================================================================
# Step 1: Generate Root CA
# =============================================================================

echo -e "\n${YELLOW}[1/6] Generating Root CA...${NC}"

# Create CA private key
openssl genrsa -out ca/ca-key.pem 4096

# Create CA certificate
openssl req -new -x509 \
  -key ca/ca-key.pem \
  -out ca/ca-cert.pem \
  -days "$VALIDITY_DAYS" \
  -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Engineering/CN=Kafka-CA"

echo -e "${GREEN}✓ Root CA generated${NC}"

# =============================================================================
# Step 2: Create JKS Truststore with CA
# =============================================================================

echo -e "\n${YELLOW}[2/6] Creating truststore...${NC}"

# Import CA cert into truststore
keytool -import -noprompt \
  -keystore ca/kafka.truststore.jks \
  -storepass "$TRUSTSTORE_PASSWORD" \
  -alias ca-root \
  -file ca/ca-cert.pem

echo -e "${GREEN}✓ Truststore created: ca/kafka.truststore.jks${NC}"

# =============================================================================
# Step 3: Generate Server Certificates for Each Broker
# =============================================================================

echo -e "\n${YELLOW}[3/6] Generating broker certificates (0 to $((NUM_BROKERS-1)))...${NC}"

for i in $(seq 0 $((NUM_BROKERS-1))); do
  BROKER_NAME="${CLUSTER_NAME}-${i}"
  BROKER_FQDN="${BROKER_NAME}.${CLUSTER_NAME}.${DOMAIN}"

  echo -e "  Generating certificate for: ${BROKER_FQDN}"

  mkdir -p "brokers/${BROKER_NAME}"

  # Generate broker private key
  openssl genrsa -out "brokers/${BROKER_NAME}/server-key.pem" 2048

  # Create certificate signing request (CSR)
  openssl req -new \
    -key "brokers/${BROKER_NAME}/server-key.pem" \
    -out "brokers/${BROKER_NAME}/server.csr" \
    -subj "/C=US/ST=CA/L=MountainView/O=Confluent/OU=Engineering/CN=${BROKER_FQDN}"

  # Create SAN configuration for broker
  cat > "brokers/${BROKER_NAME}/san.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = CA
L = MountainView
O = Confluent
OU = Engineering
CN = ${BROKER_FQDN}

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${BROKER_FQDN}
DNS.2 = ${BROKER_NAME}
DNS.3 = ${CLUSTER_NAME}.${DOMAIN}
DNS.4 = ${CLUSTER_NAME}
DNS.5 = localhost
EOF

  # Sign the certificate with CA
  openssl x509 -req \
    -in "brokers/${BROKER_NAME}/server.csr" \
    -CA ca/ca-cert.pem \
    -CAkey ca/ca-key.pem \
    -CAcreateserial \
    -out "brokers/${BROKER_NAME}/server-cert.pem" \
    -days "$VALIDITY_DAYS" \
    -extensions v3_req \
    -extfile "brokers/${BROKER_NAME}/san.cnf"

  # Create PKCS12 keystore
  openssl pkcs12 -export \
    -in "brokers/${BROKER_NAME}/server-cert.pem" \
    -inkey "brokers/${BROKER_NAME}/server-key.pem" \
    -out "brokers/${BROKER_NAME}/server.p12" \
    -name "${BROKER_FQDN}" \
    -CAfile ca/ca-cert.pem \
    -caname ca-root \
    -password "pass:${KEYSTORE_PASSWORD}"

  # Convert PKCS12 to JKS keystore
  keytool -importkeystore \
    -srckeystore "brokers/${BROKER_NAME}/server.p12" \
    -srcstoretype PKCS12 \
    -srcstorepass "$KEYSTORE_PASSWORD" \
    -destkeystore "brokers/${BROKER_NAME}/kafka.keystore.jks" \
    -deststoretype JKS \
    -deststorepass "$KEYSTORE_PASSWORD" \
    -noprompt

  # Verify the keystore
  keytool -list -v \
    -keystore "brokers/${BROKER_NAME}/kafka.keystore.jks" \
    -storepass "$KEYSTORE_PASSWORD" > "brokers/${BROKER_NAME}/keystore-info.txt"

done

echo -e "${GREEN}✓ Generated certificates for $NUM_BROKERS brokers${NC}"

# =============================================================================
# Step 4: Create Kubernetes Secrets
# =============================================================================

echo -e "\n${YELLOW}[4/6] Creating Kubernetes secret YAML files...${NC}"

# Secret for TLS (server certificates)
cat > secrets/kafka-tls-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: kafka-tls
  namespace: $NAMESPACE
type: Opaque
data:
  # Base64 encoded JKS keystore (same for all brokers in this simple setup)
  # In production, you might want per-broker secrets
  keystore.jks: $(base64 < brokers/${CLUSTER_NAME}-0/kafka.keystore.jks | tr -d '\n')
  truststore.jks: $(base64 < ca/kafka.truststore.jks | tr -d '\n')
stringData:
  # Passwords in plain text (Kubernetes will encode them)
  keystore-password: "$KEYSTORE_PASSWORD"
  truststore-password: "$TRUSTSTORE_PASSWORD"
  key-password: "$KEY_PASSWORD"
EOF

# Secret for CA certificate (for clients)
cat > secrets/kafka-ca-secret.yaml <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: kafka-ca-pair
  namespace: $NAMESPACE
type: Opaque
data:
  ca-cert.pem: $(base64 < ca/ca-cert.pem | tr -d '\n')
  ca-key.pem: $(base64 < ca/ca-key.pem | tr -d '\n')
EOF

# Combined secret file
cat > secrets/apply-secrets.yaml <<EOF
# =============================================================================
# Kafka TLS Secrets for mTLS Configuration
# Generated: $(date)
# =============================================================================
---
apiVersion: v1
kind: Secret
metadata:
  name: kafka-tls
  namespace: $NAMESPACE
type: Opaque
data:
  keystore.jks: $(base64 < brokers/${CLUSTER_NAME}-0/kafka.keystore.jks | tr -d '\n')
  truststore.jks: $(base64 < ca/kafka.truststore.jks | tr -d '\n')
stringData:
  keystore-password: "$KEYSTORE_PASSWORD"
  truststore-password: "$TRUSTSTORE_PASSWORD"
  key-password: "$KEY_PASSWORD"

---
apiVersion: v1
kind: Secret
metadata:
  name: kafka-ca-pair
  namespace: $NAMESPACE
type: Opaque
data:
  ca-cert.pem: $(base64 < ca/ca-cert.pem | tr -d '\n')
  ca-key.pem: $(base64 < ca/ca-key.pem | tr -d '\n')
EOF

echo -e "${GREEN}✓ Kubernetes secrets created${NC}"

# =============================================================================
# Step 5: Create Certificate Info Summary
# =============================================================================

echo -e "\n${YELLOW}[5/6] Creating certificate summary...${NC}"

cat > CERTIFICATE-INFO.txt <<EOF
╔══════════════════════════════════════════════════════════════════════════╗
║                 Kafka Self-Signed Certificate Summary                    ║
╚══════════════════════════════════════════════════════════════════════════╝

Generation Date: $(date)
Validity: $VALIDITY_DAYS days (~10 years)
Number of Brokers: $NUM_BROKERS

═══════════════════════════════════════════════════════════════════════════

📁 GENERATED FILES:

ca/
  ├── ca-key.pem                Root CA private key
  ├── ca-cert.pem               Root CA certificate
  ├── kafka.truststore.jks      JKS truststore (contains CA cert)

brokers/${CLUSTER_NAME}-{0..11}/
  ├── server-key.pem            Broker private key
  ├── server-cert.pem           Broker certificate (signed by CA)
  ├── kafka.keystore.jks        JKS keystore (contains private key + cert)
  └── keystore-info.txt         Keystore verification details

secrets/
  ├── apply-secrets.yaml        Combined Kubernetes secrets (APPLY THIS)
  ├── kafka-tls-secret.yaml     TLS secret (individual)
  └── kafka-ca-secret.yaml      CA secret (individual)

═══════════════════════════════════════════════════════════════════════════

🔐 PASSWORDS:

Keystore Password:   $KEYSTORE_PASSWORD
Truststore Password: $TRUSTSTORE_PASSWORD
Key Password:        $KEY_PASSWORD

⚠️  Store these passwords securely! They are embedded in the Kubernetes secrets.

═══════════════════════════════════════════════════════════════════════════

📋 CERTIFICATE DETAILS:

Root CA:
  Subject: /C=US/ST=CA/L=MountainView/O=Confluent/OU=Engineering/CN=Kafka-CA
  Validity: $VALIDITY_DAYS days
  Key Size: 4096 bits

Broker Certificates:
  Subject Pattern: /C=US/ST=CA/L=MountainView/O=Confluent/OU=Engineering/CN=${CLUSTER_NAME}-{N}.${CLUSTER_NAME}.${DOMAIN}
  SAN: ${CLUSTER_NAME}-{N}.${CLUSTER_NAME}.${DOMAIN}, ${CLUSTER_NAME}.${DOMAIN}, localhost
  Validity: $VALIDITY_DAYS days
  Key Size: 2048 bits

═══════════════════════════════════════════════════════════════════════════

✅ NEXT STEPS:

1. Review the generated certificates:
   openssl x509 -in ca/ca-cert.pem -text -noout
   openssl x509 -in brokers/${CLUSTER_NAME}-0/server-cert.pem -text -noout

2. Apply Kubernetes secrets:
   kubectl apply -f secrets/apply-secrets.yaml

3. Verify secrets were created:
   kubectl get secrets -n $NAMESPACE | grep kafka

4. Update your Kafka CRD with TLS configuration:
   See ../kafka-mtls.yaml for the complete configuration

5. Apply the Kafka CRD:
   kubectl apply -f ../kafka-mtls.yaml

═══════════════════════════════════════════════════════════════════════════

🔍 VERIFICATION:

After deploying, verify TLS is working:

# Check Kafka broker logs for TLS
kubectl logs -n $NAMESPACE kafka-0 | grep -i ssl

# Test connection with SSL
openssl s_client -connect kafka-0.kafka.${DOMAIN}:9092 \
  -CAfile ca/ca-cert.pem

# Test with kafka-broker-api-versions (requires SSL config)
kafka-broker-api-versions \
  --bootstrap-server kafka.${DOMAIN}:9092 \
  --command-config client-ssl.properties

═══════════════════════════════════════════════════════════════════════════

⚠️  IMPORTANT SECURITY NOTES:

• Keep ca-key.pem SECURE - anyone with this can sign certificates
• Rotate certificates before expiration ($VALIDITY_DAYS days)
• In production, consider using cert-manager or Vault for automation
• Store passwords in a secure secret manager (not in files)
• Limit access to the $NAMESPACE namespace

═══════════════════════════════════════════════════════════════════════════
EOF

cat CERTIFICATE-INFO.txt

# =============================================================================
# Step 6: Create Client Configuration Sample
# =============================================================================

echo -e "\n${YELLOW}[6/6] Creating client configuration sample...${NC}"

cat > ../client-ssl.properties <<EOF
# Kafka Client SSL Configuration
# Generated: $(date)

# Security protocol
security.protocol=SSL

# Truststore configuration (to trust the Kafka brokers)
ssl.truststore.location=./generated-certs/ca/kafka.truststore.jks
ssl.truststore.password=$TRUSTSTORE_PASSWORD

# Keystore configuration (for client authentication - mTLS)
# Uncomment if clients need to authenticate with certificates
#ssl.keystore.location=./client-keystore.jks
#ssl.keystore.password=$KEYSTORE_PASSWORD
#ssl.key.password=$KEY_PASSWORD

# SSL endpoint identification (hostname verification)
ssl.endpoint.identification.algorithm=https
EOF

# =============================================================================
# Summary
# =============================================================================

echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              Certificate Generation Complete!                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"

echo -e "\n${GREEN}✓ Generated certificates for $NUM_BROKERS Kafka brokers${NC}"
echo -e "${GREEN}✓ Created Kubernetes secrets YAML${NC}"
echo -e "${GREEN}✓ Created client configuration sample${NC}"

echo -e "\n📁 All files saved to: ${YELLOW}$CERT_DIR/${NC}"
echo -e "\n📋 Next steps:"
echo -e "   1. Review: ${YELLOW}cat $CERT_DIR/CERTIFICATE-INFO.txt${NC}"
echo -e "   2. Apply secrets: ${YELLOW}kubectl apply -f $CERT_DIR/secrets/apply-secrets.yaml${NC}"
echo -e "   3. Deploy Kafka with mTLS: ${YELLOW}kubectl apply -f kafka-mtls.yaml${NC}"

echo -e "\n${YELLOW}⚠️  Store passwords securely and protect ca-key.pem!${NC}\n"
