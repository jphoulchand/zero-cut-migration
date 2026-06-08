#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status

# --- CONFIGURATION ---
BASH_PROFILE="$HOME/.bash_profile"
INSTALL_BASE="/opt/binaries"
JAVA_URL="https://corretto.aws/downloads/latest/amazon-corretto-21-x64-linux-jdk.tar.gz"
KAFKA_URL="https://packages.confluent.io/archive/8.2/confluent-8.2.1.tar.gz"

echo "--- Installing system dependencies ---"
sudo yum install -y nc bind-utils unzip git

# Ensure wget is installed (for robust environments)
if ! command -v wget &> /dev/null; then
    echo "wget not found. Attempting to install..."
    # Assuming Debian/Ubuntu or RedHat/CentOS compatibility
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y wget
    elif command -v yum &> /dev/null; then
        sudo yum install -y wget
    else
        echo "Error: Cannot find package manager to install wget. Please install it manually."
        exit 1
    fi
fi


# --- 1. DIRECTORY PREPARATION ---

echo "--- 1. Preparing Installation Directory ---"
sudo mkdir -p "$INSTALL_BASE"
sudo chown -R $(whoami): "$INSTALL_BASE"


# --- 2. INSTALL JAVA (AMAZON CORRETTO 21) ---

echo -e "\n--- 2. Installing Java (Amazon Corretto 21) ---"
JAVA_ROOT="$INSTALL_BASE/jdk"
JAVA_FILENAME=$(basename "$JAVA_URL")

# Download using wget
echo "Downloading $JAVA_FILENAME to /tmp/..."
wget -q "$JAVA_URL" -O "/tmp/$JAVA_FILENAME" || { echo "ERROR: Failed to download Java"; exit 1; }

# Extract to predictable 'jdk' directory
echo "Extracting Java to $JAVA_ROOT..."
mkdir -p "$JAVA_ROOT"
tar -xzf "/tmp/$JAVA_FILENAME" --strip-components=1 -C "$JAVA_ROOT"

JAVA_BIN="$JAVA_ROOT/bin"

# Ensure bash_profile exists
touch "$BASH_PROFILE"

# Update BASH_PROFILE for JAVA_HOME and PATH (idempotent)
if ! grep -q "^export JAVA_HOME=" "$BASH_PROFILE"; then
  echo "Updating $BASH_PROFILE for Java environment variables..."
  {
    echo ""
    echo "# --- Custom Environment Setup (Java & Kafka) ---"
    echo "export JAVA_HOME=\"$JAVA_ROOT\""
    echo "export PATH=\"\$JAVA_HOME/bin:\$PATH\""
  } >> "$BASH_PROFILE"
  echo "✓ Added Java to $BASH_PROFILE"
else
  echo "Java environment already configured in $BASH_PROFILE, skipping."
fi

# Clean up temporary file
rm -f "/tmp/$JAVA_FILENAME"


# --- 3. INSTALL KAFKA (CONFLUENT PLATFORM) ---

echo -e "\n--- 3. Installing Confluent Platform ---"
KAFKA_ROOT="$INSTALL_BASE/cp"
KAFKA_FILENAME=$(basename "$KAFKA_URL")

# Download using wget
echo "Downloading $KAFKA_FILENAME to /tmp/..."
wget -q "$KAFKA_URL" -O "/tmp/$KAFKA_FILENAME" || { echo "ERROR: Failed to download Confluent Platform"; exit 1; }

# Extract to predictable 'kafka' directory
echo "Extracting Kafka to $KAFKA_ROOT..."
mkdir -p "$KAFKA_ROOT"
tar -xzf "/tmp/$KAFKA_FILENAME" --strip-components=1 -C "$KAFKA_ROOT"

KAFKA_BIN="$KAFKA_ROOT/bin"

# Update BASH_PROFILE for Kafka PATH (idempotent)
# Check if Kafka bin path is already in PATH variable
if ! grep -q "$KAFKA_BIN" "$BASH_PROFILE"; then
  echo "Updating $BASH_PROFILE for Kafka CLI tools..."
  echo "export PATH=\"\$PATH:$KAFKA_BIN\"" >> "$BASH_PROFILE"
  echo "✓ Added Kafka to $BASH_PROFILE"
else
  echo "Kafka PATH already configured in $BASH_PROFILE, skipping."
fi

# Clean up temporary file
rm -f "/tmp/$KAFKA_FILENAME"


# --- 4. ACTIVATE ENVIRONMENT ---

echo -e "\n--- 4. Activation and Verification ---"

# Source the updated profile to activate in current session
echo "Activating environment variables..."
source "$BASH_PROFILE"

echo ""
# --- 5. INSTALL KUBECTL ---

echo -e "\n--- 5. Installing kubectl ---"
KUBECTL_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
echo "Downloading kubectl $KUBECTL_VERSION..."
curl -sLo /tmp/kubectl "https://storage.googleapis.com/kubernetes-release/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm -f /tmp/kubectl
echo "✓ kubectl installed: $(kubectl version --client 2>&1 | grep 'Client Version')"


# --- 6. INSTALL HELM ---

echo -e "\n--- 6. Installing Helm ---"
curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "✓ Helm installed: $(helm version --short)"


# --- 7. INSTALL AWS CLI v2 ---

echo -e "\n--- 7. Installing AWS CLI v2 ---"
cd /tmp
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install --update 2>/dev/null || sudo ./aws/install
rm -rf aws awscliv2.zip
echo "✓ AWS CLI installed: $(aws --version)"


# --- 8. FINAL SUMMARY ---

echo ""
echo "=========================================="
echo "Installation Complete!"
echo "=========================================="
echo ""
echo "Installed components:"
echo "  • Java (Corretto 21): $JAVA_ROOT"
echo "  • Confluent Platform: $KAFKA_ROOT"
echo "  • kubectl: $(kubectl version --client 2>&1 | grep 'Client Version')"
echo "  • Helm: $(helm version --short 2>&1)"
echo "  • AWS CLI: $(aws --version 2>&1)"
echo "  • Rancher CLI: install separately if needed"
echo ""
echo "Verification:"
echo "  • JAVA_HOME: $JAVA_HOME"
echo "  • Java version: $(java -version 2>&1 | head -1)"
echo "  • Kafka CLI: $(which kafka-topics 2>/dev/null || echo 'not in PATH')"
echo ""
echo "Environment configured in: $BASH_PROFILE"
echo ""
echo "To activate in a new shell session, run:"
echo "  source ~/.bash_profile"
echo ""
echo "=========================================="