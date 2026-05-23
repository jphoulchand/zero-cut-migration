# AWS Cost Analysis - May 2026

**Project:** jph-demo  
**Period:** May 1-23, 2026 (23 days)  
**Total Cost (23 days):** $379.13  
**Projected Full Month:** $511.00  
**Daily Average:** $16.48

---

## Cost Breakdown by Service

| Service | Cost (23 days) | % of Total | Projected Monthly |
|---------|----------------|------------|-------------------|
| **EC2 Compute** | $163.57 | 43.1% | $220.47 |
| **EC2 - Other** (EBS, IPs, etc.) | $84.85 | 22.4% | $114.35 |
| **VPC** (VPC Endpoints) | $68.12 | 18.0% | $91.83 |
| **EKS Control Plane** | $51.50 | 13.6% | $73.00 |
| **CloudWatch** | $10.39 | 2.7% | $14.00 |
| **KMS** | $0.70 | 0.2% | $0.94 |
| **TOTAL** | **$379.13** | **100%** | **$511.00** |

---

## EC2 Instance Usage

### Instance Types

| Instance Type | Usage Type | Cost (23 days) | Hours | Unit Cost |
|---------------|------------|----------------|-------|-----------|
| **t3.large** | On-Demand (System Nodes) | $93.58 | ~1,028 hrs | $0.091/hr |
| **c6g.xlarge** | Spot (Kafka/Karpenter) | $69.98 | ~1,213 hrs | $0.058/hr |

### Analysis

- **System Nodes (t3.large)**: 2 nodes × 23 days × 24 hours = 1,104 hours (expected)
  - Actual: 1,028 hours (93% uptime)
  - Cost: $93.58 ($0.091/hour on-demand)

- **Karpenter Nodes (c6g.xlarge)**: Variable spot instances
  - Total: 1,213 hours across all Kafka pods
  - Cost: $69.98 (spot pricing ~$0.058/hour, 65% discount)
  - **Optimization**: Using ARM64 c6g.xlarge is 35% cheaper than x86 c5.xlarge

---

## VPC Cost Breakdown

**Total VPC Cost:** $68.12 (18% of total)

### VPC Endpoints

| Endpoint | Type | AZs | Cost/Hour | Daily Cost | 23-Day Cost |
|----------|------|-----|-----------|------------|-------------|
| STS | Interface | 3 | $0.03 | $0.72 | $16.56 |
| EC2 | Interface | 3 | $0.03 | $0.72 | $16.56 |
| ECR API | Interface | 3 | $0.03 | $0.72 | $16.56 |
| ECR DKR | Interface | 3 | $0.03 | $0.72 | $16.56 |
| S3 | Gateway | - | FREE | FREE | FREE |
| **TOTAL** | | | **$0.12** | **$2.88** | **$66.24** |

**Data Transfer:** $1.88 (VPC endpoint data processing)

### Why VPC Endpoints?

VPC Endpoints enable private connectivity to AWS services without internet gateway:
- **Security**: No public internet exposure for ECR, STS, EC2 API calls
- **Required for Spot**: Karpenter needs EC2 API access in private subnets
- **Required for Images**: ECR access for pulling container images
- **Cost Trade-off**: $92/month VPC endpoints vs NAT Gateway ($32/month + $0.045/GB)
  - With high ECR traffic, VPC endpoints can be cheaper than NAT + data transfer
  - More secure architecture

---

## Cost vs Budget Analysis

### Original Estimate (from README.md)

| Component | Estimated | Actual (Projected) | Variance |
|-----------|-----------|-------------------|----------|
| EKS Control Plane | $73 | $73 | ✓ Match |
| System Nodes (2x t3.large) | $120 | $126 | +$6 |
| Kafka Brokers (spot) | $85 | $94 | +$9 |
| VPC/Networking | $15 | $92 | **+$77** |
| CloudWatch | - | $14 | +$14 |
| KMS | - | $1 | +$1 |
| Other (EBS, IPs) | $57 | $114 | +$57 |
| **TOTAL** | **$364** | **$511** | **+$147 (40% over)** |

### Key Discrepancies

1. **VPC Cost ($92 vs $15 estimated)**: VPC Endpoints cost $0.12/hour = $92/month
   - 4 Interface endpoints × 3 AZs × $0.01/hour
   - This was underestimated in the original budget

2. **EC2 Other ($114 vs $57 estimated)**: Includes:
   - EBS volumes for Kafka brokers (12 × 50GB)
   - Elastic IPs
   - Data transfer

3. **CloudWatch ($14)**: Metrics and logs for EKS cluster

---

## Cost Optimization Opportunities

### ✅ Already Optimized

1. **Spot Instances**: Karpenter using spot = ~65% savings on compute
2. **ARM64**: c6g.xlarge is 35% cheaper than c5.xlarge
3. **NodePort DNS**: Avoiding NLB ($16/month) by using NodePort
4. **S3 Gateway Endpoint**: FREE vs Interface endpoint

### ⚠️ Potential Savings

1. **VPC Endpoints** ($92/month):
   - **Option A**: Replace with NAT Gateway ($32/month + data transfer)
     - Saves ~$60/month if ECR data transfer is low
     - **Risk**: Less secure (internet gateway required)
   - **Option B**: Keep 2 endpoints (ECR API/DKR), remove STS/EC2
     - Saves ~$46/month
     - **Risk**: May break Karpenter EC2 API calls
   - **Recommendation**: **Keep current setup** - security benefits outweigh cost

2. **System Nodes** ($126/month):
   - Currently using 2× t3.large on-demand for stability
   - **Option**: Switch to spot t3.large
     - Saves ~$80/month
     - **Risk**: System node interruption could impact cluster DNS, monitoring
   - **Recommendation**: **Keep on-demand** - critical infrastructure

3. **EBS Volumes** (part of $114 EC2 Other):
   - 12 brokers × 50GB = 600GB total
   - **Option**: Reduce broker storage to 30GB if usage is low
     - Saves ~$8/month
   - **Recommendation**: Monitor actual usage, reduce if <30GB used

### 💡 Best Cost Optimization

**Reduce Kafka Broker Count** (if workload allows):
- Current: 12 brokers = ~$94/month compute + ~$24/month storage
- Reduce to 6 brokers: Save ~$47/month compute + $12/month storage
- **Total Savings: ~$59/month** (projected $511 → $452)

**Trade-off**: Lower throughput, less redundancy

---

## Daily Cost Trend

| Date | Daily Cost | Notes |
|------|------------|-------|
| May 15 | $13.86 | |
| May 16 | $13.86 | |
| May 17 | $13.86 | |
| May 18 | $13.86 | |
| May 19 | $13.86 | Consistent daily cost |
| May 20 | $13.65 | |
| May 21 | $13.65 | |
| May 22 | $6.12 | Partial day (cluster stopped?) |
| May 23 | $0.00 | No usage reported yet |

**Average Daily Cost:** $16.48 (across 23 days)

---

## Recommendations

### Immediate Actions

1. **Accept Current Cost** ($511/month)
   - VPC Endpoints are necessary for secure, private subnet architecture
   - Cost is predictable and stable (~$16.50/day)

2. **Monitor EBS Usage**
   - Check actual disk usage on Kafka brokers
   - Reduce from 50GB to 30GB if possible (save ~$8/month)

3. **Review Kafka Broker Count**
   - If workload is low, consider reducing from 12 to 6-8 brokers
   - Potential savings: $50-70/month

### Long-Term Optimization

1. **NAT Gateway vs VPC Endpoints**
   - After 3 months, analyze ECR data transfer volumes
   - If <500GB/month ECR pulls, NAT might be cheaper
   - Calculate: NAT ($32) + Transfer ($0.045×GB) vs VPC Endpoints ($92)

2. **Reserved Instances for System Nodes**
   - If cluster runs 24/7 for >1 year, buy Reserved Instances
   - Save 30-40% on t3.large cost ($126 → $75)

3. **Right-size Kafka Brokers**
   - Monitor CPU/memory usage of c6g.xlarge instances
   - If usage <30%, downgrade to c6g.large (save ~$47/month)

---

## Summary

**Current Status:**
- ✅ Production Kafka cluster running smoothly
- ✅ Cost-optimized with spot instances and ARM64
- ✅ Secure architecture with VPC endpoints
- ⚠️ 40% over original budget due to VPC endpoint underestimation

**Actual Monthly Cost:** $511 (vs $364 estimated)

**Primary Cost Driver:** VPC Endpoints ($92/month) - necessary for security

**Recommendation:** **Accept current cost** and monitor for workload optimization opportunities. The VPC endpoint cost is a reasonable trade-off for a secure, production-ready Kafka deployment.
