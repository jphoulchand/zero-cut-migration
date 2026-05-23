# Terraform Scripts

Scripts used by Terraform for infrastructure provisioning and configuration.

## Scripts

### install_binaries.sh

**Purpose**: Installs Java and Confluent Platform on the jumpbox

**Installed Components**:
- Amazon Corretto 21 (JDK)
- Confluent Platform 8.2.1
- Kafka CLI tools
- netcat and bind-utils

**Usage**: Automatically executed via cloud-init on jumpbox creation

**Location**: `/opt/binaries/` on jumpbox
- Java: `/opt/binaries/jdk/`
- Confluent: `/opt/binaries/cp/`

---

### setup_dns.sh

**Purpose**: Configures DNS on jumpbox to resolve Kubernetes cluster.local domains

**Method**: Sets up dnsmasq to forward queries to EKS system nodes via NodePort 30053

**Usage**: Automatically executed via cloud-init on jumpbox creation

**Template Variables**:
- `${system_node_ips}` - Space-separated list of system node IPs

**Configuration Files Created**:
- `/etc/dnsmasq.d/kube-dns.conf` - dnsmasq forwarding rules
- `/etc/systemd/resolved.conf.d/kube-dns.conf` - systemd-resolved config

**Architecture**:
```
Jumpbox -> dnsmasq (127.0.0.1) -> System Nodes:30053 -> CoreDNS
```

**See Also**: [../kafka/DNS-ARCHITECTURE.md](../../kafka/DNS-ARCHITECTURE.md)

---

### setup-jumpbox-dns-nodeport.sh

**Purpose**: Standalone script to manually configure DNS on jumpbox

**Difference from setup_dns.sh**:
- `setup_dns.sh`: Template used by Terraform cloud-init
- `setup-jumpbox-dns-nodeport.sh`: Standalone script for manual execution

**Usage**:
```bash
# Copy to jumpbox
scp -i ~/.ssh/jphoulchand_csta.pem tf/scripts/setup-jumpbox-dns-nodeport.sh ec2-user@<jumpbox-ip>:~/

# SSH and run
ssh -i ~/.ssh/jphoulchand_csta.pem ec2-user@<jumpbox-ip>
sudo bash setup-jumpbox-dns-nodeport.sh
```

**When to Use**:
- Jumpbox created before DNS configuration was added
- System node IPs changed
- Need to reconfigure DNS without recreating jumpbox

---

### validate_tfvars.sh

**Purpose**: Validates terraform.tfvars before running `terraform apply`

**Checks**:
- Required variables are set
- CIDR block format is valid
- SSH key file exists
- AWS credentials are configured

**Usage**:
```bash
cd tf
./scripts/validate_tfvars.sh
```

**Exit Codes**:
- 0: Validation passed
- 1: Validation failed

---

### find_cidr.py

**Purpose**: Helper script to find available CIDR blocks in AWS

**Usage**:
```bash
cd tf/scripts
python3 find_cidr.py
```

**Output**: List of available /16 CIDR blocks in the specified AWS region

---

## Cloud-Init Process

When the jumpbox is created, Terraform executes these scripts via `user_data`:

1. **install_binaries.sh**: Installs Java and Confluent Platform
2. **setup_dns.sh**: Configures DNS for cluster access

Both scripts run automatically on first boot.

## Manual Reconfiguration

If you need to reconfigure the jumpbox manually:

### Reinstall Binaries

```bash
# SSH to jumpbox
ssh -i ~/.ssh/jphoulchand_csta.pem ec2-user@<jumpbox-ip>

# Download and run install script
curl -O https://raw.githubusercontent.com/.../install_binaries.sh
sudo bash install_binaries.sh
```

### Reconfigure DNS

```bash
# Option 1: Use standalone script
scp -i ~/.ssh/jphoulchand_csta.pem tf/scripts/setup-jumpbox-dns-nodeport.sh ec2-user@<jumpbox-ip>:~/
ssh -i ~/.ssh/jphoulchand_csta.pem ec2-user@<jumpbox-ip>
sudo bash setup-jumpbox-dns-nodeport.sh

# Option 2: Manual configuration (see kafka/CONFIGURE-JUMPBOX-DNS.md)
```

## Troubleshooting

### Check Cloud-Init Logs

```bash
# SSH to jumpbox
ssh -i ~/.ssh/jphoulchand_csta.pem ec2-user@<jumpbox-ip>

# View cloud-init output
sudo cat /var/log/cloud-init-output.log

# Check cloud-init status
cloud-init status

# View detailed logs
sudo journalctl -u cloud-init
```

### Verify Installations

```bash
# Check Java
java -version
echo $JAVA_HOME

# Check Kafka tools
kafka-topics --version
which kafka-topics

# Check DNS
dig kafka.confluent.svc.cluster.local +short

# Check dnsmasq
systemctl status dnsmasq
```

## References

- Terraform: [../main.tf](../main.tf)
- Jumpbox Config: [../jumpbox.tf](../jumpbox.tf)
- DNS Config: [../dns.tf](../dns.tf)
- DNS Architecture: [../../kafka/DNS-ARCHITECTURE.md](../../kafka/DNS-ARCHITECTURE.md)
