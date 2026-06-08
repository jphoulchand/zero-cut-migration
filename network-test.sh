#!/bin/bash
# =============================================================================
# Network Performance Test Suite
# =============================================================================
#
# Tests cross-AZ network throughput between 3 busybox-debug pods
# Each pod runs on a different availability zone on Karpenter ARM64 nodes
#
# Usage:
#   ./network-test.sh
#
# Prerequisites:
#   - kubectl configured for the cluster
#   - busybox-debug pods deployed (kubectl apply -f busybox-debug-deployment.yaml)
#
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Network Performance Test Suite ===${NC}"
echo ""

# Check if pods are running
echo -e "${YELLOW}Checking pod status...${NC}"
if ! kubectl get pods -n confluent -l app=busybox-debug &> /dev/null; then
    echo -e "${RED}Error: busybox-debug pods not found${NC}"
    echo "Please deploy first: kubectl apply -f busybox-debug-deployment.yaml"
    exit 1
fi

POD_COUNT=$(kubectl get pods -n confluent -l app=busybox-debug --field-selector=status.phase=Running --no-headers | wc -l | tr -d ' ')
if [ "$POD_COUNT" -ne 3 ]; then
    echo -e "${RED}Error: Expected 3 running pods, found $POD_COUNT${NC}"
    kubectl get pods -n confluent -l app=busybox-debug
    exit 1
fi

echo -e "${GREEN}✓ All 3 pods are running${NC}"
echo ""

# Display pod distribution
echo -e "${YELLOW}Pod distribution across AZs:${NC}"
kubectl get pods -n confluent -l app=busybox-debug -o custom-columns=\
NAME:.metadata.name,\
IP:.status.podIP,\
NODE:.spec.nodeName,\
AZ:.metadata.labels.'topology\.kubernetes\.io/zone'
echo ""

# Get pod IPs
POD0_IP=$(kubectl get pod busybox-debug-0 -n confluent -o jsonpath='{.status.podIP}')
POD1_IP=$(kubectl get pod busybox-debug-1 -n confluent -o jsonpath='{.status.podIP}')
POD2_IP=$(kubectl get pod busybox-debug-2 -n confluent -o jsonpath='{.status.podIP}')

echo -e "${YELLOW}Pod IPs:${NC}"
echo "  busybox-debug-0: $POD0_IP"
echo "  busybox-debug-1: $POD1_IP"
echo "  busybox-debug-2: $POD2_IP"
echo ""

# Test parameters
DATA_SIZE=1000  # MB
BUFFER_SIZE=65536  # 64 KB

echo -e "${BLUE}Test parameters:${NC}"
echo "  Data size: ${DATA_SIZE} MB"
echo "  Buffer size: ${BUFFER_SIZE} bytes (64 KB)"
echo ""

echo -e "${BLUE}=== Starting Cross-AZ Network Tests ===${NC}"
echo ""

# Test 1: Pod-0 → Pod-1
echo -e "${YELLOW}Test 1/6: Pod-0 → Pod-1 (Cross-AZ)${NC}"
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

# Test 2: Pod-0 → Pod-2
echo -e "${YELLOW}Test 2/6: Pod-0 → Pod-2 (Cross-AZ)${NC}"
kubectl exec busybox-debug-0 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

# Test 3: Pod-1 → Pod-0
echo -e "${YELLOW}Test 3/6: Pod-1 → Pod-0 (Cross-AZ)${NC}"
kubectl exec busybox-debug-1 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD0_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

# Test 4: Pod-1 → Pod-2
echo -e "${YELLOW}Test 4/6: Pod-1 → Pod-2 (Cross-AZ)${NC}"
kubectl exec busybox-debug-1 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD2_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

# Test 5: Pod-2 → Pod-0
echo -e "${YELLOW}Test 5/6: Pod-2 → Pod-0 (Cross-AZ)${NC}"
kubectl exec busybox-debug-2 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD0_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

# Test 6: Pod-2 → Pod-1
echo -e "${YELLOW}Test 6/6: Pod-2 → Pod-1 (Cross-AZ)${NC}"
kubectl exec busybox-debug-2 -n confluent -- \
  python /scripts/netperf.py -m client -a $POD1_IP -p 5001 -d $DATA_SIZE -b $BUFFER_SIZE
echo ""

echo -e "${GREEN}=== All tests completed successfully ===${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo "  ✓ 6 cross-AZ network throughput tests completed"
echo "  ✓ Each direction tested between all 3 availability zones"
echo "  ✓ Total data transferred: $(($DATA_SIZE * 6)) MB"
echo ""
