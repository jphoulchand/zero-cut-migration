#!/bin/bash
# =============================================================================
# validate_tfvars.sh
#
# Validates terraform.tfvars before running terraform plan/apply.
# Checks format, local file existence, and live AWS state (CIDR conflicts,
# key pair existence, AZ validity, instance type availability).
#
# Usage:
#   ./scripts/validate_tfvars.sh [path/to/terraform.tfvars]
#
# Requires: aws CLI, authenticated session (aws sts get-caller-identity).
# =============================================================================

set -euo pipefail

TFVARS="${1:-$(dirname "$0")/../terraform.tfvars}"
TFVARS="$(realpath "$TFVARS")"

# --------------------------------------------------------------------------- #
# Colours & helpers
# --------------------------------------------------------------------------- #
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

ERRORS=0
WARNINGS=0

pass()  { echo -e "  ${GREEN}✓${RESET} $*"; }
fail()  { echo -e "  ${RED}✗${RESET} $*"; ((ERRORS++)) || true; }
warn()  { echo -e "  ${YELLOW}!${RESET} $*"; ((WARNINGS++)) || true; }
header(){ echo -e "\n${BOLD}$*${RESET}"; }

# --------------------------------------------------------------------------- #
# Parse terraform.tfvars  (key = "value"  or  key = value, strips comments)
# --------------------------------------------------------------------------- #
parse_var() {
  local key="$1"
  # Strip inline comments, then extract value (quoted or unquoted)
  grep -E "^\s*${key}\s*=" "$TFVARS" | grep -v '^\s*#' | tail -1 \
    | sed -E 's/^\s*[^=]+=\s*//' \
    | sed -E 's/\s*#.*$//' \
    | tr -d '"' | tr -d "'" | xargs
}

# --------------------------------------------------------------------------- #
# 0. Pre-flight: file exists and AWS session is live
# --------------------------------------------------------------------------- #
header "0. Pre-flight"

if [[ ! -f "$TFVARS" ]]; then
  echo -e "${RED}ERROR: $TFVARS not found.${RESET}"
  echo    "       Copy terraform.tfvars.example → terraform.tfvars and fill in your values."
  exit 1
fi
pass "terraform.tfvars found: $TFVARS"

if ! aws sts get-caller-identity --output text > /dev/null 2>&1; then
  echo -e "${RED}ERROR: Not authenticated to AWS. Run 'aws sso login' or set credentials.${RESET}"
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER=$(aws sts get-caller-identity --query 'Arn' --output text)
pass "AWS session active — account ${ACCOUNT_ID} (${CALLER})"

# --------------------------------------------------------------------------- #
# Read variables
# --------------------------------------------------------------------------- #
PROJECT_NAME=$(parse_var "project_name")
OWNER_EMAIL=$(parse_var "owner_email")
AWS_REGION=$(parse_var "aws_region")
JUMP_AZ=$(parse_var "jump_box_availability_zone")
CIDR=$(parse_var "vpcs_cidr_block")
K8S_VERSION=$(parse_var "kubernetes_version")
SSH_KEY_NAME=$(parse_var "ssh_key_name")
SSH_KEY_PATH=$(parse_var "ssh_private_key_path")
INSTANCE_TYPE=$(parse_var "instance_type")
SSH_USER=$(parse_var "ssh_user")

# --------------------------------------------------------------------------- #
# 1. Required fields present and not placeholder
# --------------------------------------------------------------------------- #
header "1. Required fields"

check_placeholder() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    fail "${name} is empty — not set in tfvars"
  elif echo "$value" | grep -qiE 'CHANGE_ME|your-|example\.com|10\.X\.'; then
    fail "${name} = '${value}' looks like an unfilled placeholder"
  else
    pass "${name} is set"
  fi
}

check_placeholder "project_name"              "$PROJECT_NAME"
check_placeholder "owner_email"               "$OWNER_EMAIL"
check_placeholder "aws_region"                "$AWS_REGION"
check_placeholder "jump_box_availability_zone" "$JUMP_AZ"
check_placeholder "vpcs_cidr_block"           "$CIDR"
check_placeholder "kubernetes_version"        "$K8S_VERSION"
check_placeholder "ssh_key_name"              "$SSH_KEY_NAME"
check_placeholder "ssh_private_key_path"      "$SSH_KEY_PATH"

# --------------------------------------------------------------------------- #
# 2. Format validation (no AWS calls)
# --------------------------------------------------------------------------- #
header "2. Format checks"

# project_name: lowercase alphanumeric + hyphens, 3-12 chars
if echo "$PROJECT_NAME" | grep -qE '^[a-z0-9][a-z0-9-]{2,11}$'; then
  pass "project_name format OK ('${PROJECT_NAME}')"
else
  fail "project_name '${PROJECT_NAME}' — must be 3-12 chars, lowercase letters/digits/hyphens, no leading hyphen"
fi

# email
if echo "$OWNER_EMAIL" | grep -qE '^[^@]+@[^@]+\.[^@]+$'; then
  pass "owner_email format OK"
else
  fail "owner_email '${OWNER_EMAIL}' does not look like a valid email address"
fi

# CIDR must be a /16
if echo "$CIDR" | grep -qE '^([0-9]{1,3}\.){3}0/16$'; then
  # Each octet <= 255
  IFS='.' read -r o1 o2 o3 _ <<< "${CIDR%/*}"
  if [[ $o1 -le 255 && $o2 -le 255 && $o3 -eq 0 ]]; then
    pass "vpcs_cidr_block is a valid /16 (${CIDR})"
  else
    fail "vpcs_cidr_block '${CIDR}' — third octet must be 0 for a clean /16"
  fi
else
  fail "vpcs_cidr_block '${CIDR}' — must be a /16 block (e.g. 10.19.0.0/16)"
fi

# kubernetes_version: X.YY format
if echo "$K8S_VERSION" | grep -qE '^1\.[0-9]{2}$'; then
  pass "kubernetes_version format OK (${K8S_VERSION})"
else
  fail "kubernetes_version '${K8S_VERSION}' — expected format 1.XX (e.g. 1.33)"
fi

# --------------------------------------------------------------------------- #
# 3. AWS Region
# --------------------------------------------------------------------------- #
header "3. AWS region"

if aws ec2 describe-regions \
     --region us-east-1 \
     --query "Regions[?RegionName=='${AWS_REGION}'].RegionName" \
     --output text 2>/dev/null | grep -q "$AWS_REGION"; then
  pass "Region '${AWS_REGION}' exists and is enabled"
else
  fail "Region '${AWS_REGION}' not found or not enabled in this account"
fi

# --------------------------------------------------------------------------- #
# 4. Availability Zone
# --------------------------------------------------------------------------- #
header "4. Availability Zone"

AZ_STATE=$(aws ec2 describe-availability-zones \
  --region "$AWS_REGION" \
  --query "AvailabilityZones[?ZoneName=='${JUMP_AZ}'].State" \
  --output text 2>/dev/null || true)

if [[ "$AZ_STATE" == "available" ]]; then
  pass "AZ '${JUMP_AZ}' is available in ${AWS_REGION}"
elif [[ -z "$AZ_STATE" ]]; then
  fail "AZ '${JUMP_AZ}' does not exist in region '${AWS_REGION}'"
  echo    "       Available AZs:"
  aws ec2 describe-availability-zones --region "$AWS_REGION" \
    --query 'AvailabilityZones[?State==`available`].ZoneName' \
    --output text | tr '\t' '\n' | sed 's/^/         /'
else
  fail "AZ '${JUMP_AZ}' is in state '${AZ_STATE}' (not available)"
fi

# --------------------------------------------------------------------------- #
# 5. CIDR conflict check
# --------------------------------------------------------------------------- #
header "5. CIDR conflict check"

# Extract the first two octets of our /16 to detect overlaps
IFS='.' read -r MY_O1 MY_O2 _ <<< "${CIDR%/*}"

# Fetch all VPC CIDRs in the region (primary + associated)
EXISTING_CIDRS=$(aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query 'Vpcs[*].CidrBlockAssociationSet[*].CidrBlock' \
  --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true)

CONFLICT=0
while IFS= read -r existing; do
  [[ -z "$existing" ]] && continue
  IFS='.' read -r e1 e2 _ <<< "${existing%/*}"
  EXISTING_PREFIX="${e1}.${e2}."
  MY_PREFIX="${MY_O1}.${MY_O2}."

  if [[ "$EXISTING_PREFIX" == "$MY_PREFIX" ]]; then
    fail "CIDR conflict: ${CIDR} overlaps with existing VPC CIDR ${existing}"
    CONFLICT=1
  fi
done <<< "$EXISTING_CIDRS"

if [[ $CONFLICT -eq 0 ]]; then
  TOTAL=$(echo "$EXISTING_CIDRS" | grep -c '[0-9]' || true)
  pass "No conflicts found among ${TOTAL} existing VPC CIDR(s) in ${AWS_REGION}"
fi

# --------------------------------------------------------------------------- #
# 6. SSH Key Pair
# --------------------------------------------------------------------------- #
header "6. SSH Key Pair"

KEY_EXISTS=$(aws ec2 describe-key-pairs \
  --region "$AWS_REGION" \
  --key-names "$SSH_KEY_NAME" \
  --query 'KeyPairs[0].KeyName' \
  --output text 2>/dev/null || true)

if [[ "$KEY_EXISTS" == "$SSH_KEY_NAME" ]]; then
  pass "Key pair '${SSH_KEY_NAME}' exists in ${AWS_REGION}"
else
  fail "Key pair '${SSH_KEY_NAME}' not found in region '${AWS_REGION}'"
  echo    "       To create one:"
  echo    "         aws ec2 create-key-pair --key-name ${SSH_KEY_NAME} \\"
  echo    "           --region ${AWS_REGION} --query KeyMaterial \\"
  echo    "           --output text > ~/.ssh/${SSH_KEY_NAME}.pem"
  echo    "         chmod 600 ~/.ssh/${SSH_KEY_NAME}.pem"
fi

# --------------------------------------------------------------------------- #
# 7. Local SSH private key file
# --------------------------------------------------------------------------- #
header "7. Local SSH private key"

# Expand ~ manually (realpath won't expand ~ for non-existent files)
SSH_KEY_PATH_EXPANDED="${SSH_KEY_PATH/#\~/$HOME}"

if [[ ! -f "$SSH_KEY_PATH_EXPANDED" ]]; then
  fail "Private key not found: ${SSH_KEY_PATH_EXPANDED}"
else
  PERMS=$(stat -c '%a' "$SSH_KEY_PATH_EXPANDED" 2>/dev/null \
       || stat -f '%A' "$SSH_KEY_PATH_EXPANDED" 2>/dev/null)
  if [[ "$PERMS" == "600" || "$PERMS" == "400" ]]; then
    pass "Private key found with correct permissions (${PERMS}): ${SSH_KEY_PATH_EXPANDED}"
  else
    warn "Private key found but permissions are ${PERMS} — should be 600 or 400"
    echo    "       Fix: chmod 600 ${SSH_KEY_PATH_EXPANDED}"
  fi
fi

# --------------------------------------------------------------------------- #
# 8. EC2 instance type available in region
# --------------------------------------------------------------------------- #
header "8. Instance type"

ITYPE_FOUND=$(aws ec2 describe-instance-types \
  --region "$AWS_REGION" \
  --instance-types "$INSTANCE_TYPE" \
  --query 'InstanceTypes[0].InstanceType' \
  --output text 2>/dev/null || true)

if [[ "$ITYPE_FOUND" == "$INSTANCE_TYPE" ]]; then
  pass "Instance type '${INSTANCE_TYPE}' is available in ${AWS_REGION}"
else
  fail "Instance type '${INSTANCE_TYPE}' not found in region '${AWS_REGION}'"
fi

# --------------------------------------------------------------------------- #
# 9. EKS Kubernetes version supported
# --------------------------------------------------------------------------- #
header "9. Kubernetes version"

# Use addon-versions as a proxy — EKS will only return results for valid versions
K8S_VALID=$(aws eks describe-addon-versions \
  --region "$AWS_REGION" \
  --kubernetes-version "$K8S_VERSION" \
  --query 'addons[0].addonName' \
  --output text 2>/dev/null || true)

if [[ -n "$K8S_VALID" && "$K8S_VALID" != "None" ]]; then
  pass "Kubernetes ${K8S_VERSION} is supported in ${AWS_REGION}"
else
  fail "Kubernetes ${K8S_VERSION} may not be supported by EKS in ${AWS_REGION}"
  echo    "       Check: aws eks describe-addon-versions --region ${AWS_REGION} \\"
  echo    "                --kubernetes-version ${K8S_VERSION}"
fi

# --------------------------------------------------------------------------- #
# 10. EKS service quota — VPC count headroom
# --------------------------------------------------------------------------- #
header "10. VPC quota headroom"

VPC_COUNT=$(aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query 'length(Vpcs)' \
  --output text 2>/dev/null || echo "0")

# This deployment creates 2 VPCs (EKS + Jumpbox)
NEEDED=2
REMAINING=$((5 - VPC_COUNT))   # default quota is 5; adjust if you have a higher limit

if [[ $REMAINING -ge $NEEDED ]]; then
  pass "VPC count OK: ${VPC_COUNT} existing, ${REMAINING} remaining (need ${NEEDED})"
elif [[ $REMAINING -gt 0 ]]; then
  warn "VPC headroom tight: ${VPC_COUNT} existing, ${REMAINING} remaining, need ${NEEDED} — check your quota"
else
  fail "VPC quota likely exhausted: ${VPC_COUNT} VPCs in ${AWS_REGION} (default limit 5, need ${NEEDED} more)"
  echo    "       Request an increase: https://console.aws.amazon.com/servicequotas/"
fi

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
echo ""
echo -e "${BOLD}==============================${RESET}"
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All checks passed. Ready to terraform plan.${RESET}"
elif [[ $ERRORS -eq 0 ]]; then
  echo -e "${YELLOW}${BOLD}${WARNINGS} warning(s), 0 errors. Review warnings before applying.${RESET}"
else
  echo -e "${RED}${BOLD}${ERRORS} error(s), ${WARNINGS} warning(s). Fix errors before running terraform.${RESET}"
fi
echo -e "${BOLD}==============================${RESET}"
echo ""

exit $ERRORS
