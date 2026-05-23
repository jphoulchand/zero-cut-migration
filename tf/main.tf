# =============================================================================
# 0. SETUP: PROVIDERS, TIME & LOCALS
# =============================================================================

# 1. Capture Creation Time (Static - won't change on future applies)
resource "time_static" "creation" {}

# 2. Calculate Expiration Time (Creation + 7 Days)
resource "time_offset" "expiration" {
  triggers = {
    creation_time = time_static.creation.rfc3339
  }
  offset_days = 7
}

locals {
  common_tags = {
    owner_email          = var.owner_email
    Project              = var.project_name
    ManagedBy            = "Terraform"
    Environment          = "Dev"
    CustomCreationDate   = formatdate("YYYY-MM-DD", time_static.creation.rfc3339)
    CustomExpirationDate = formatdate("YYYY-MM-DD", time_offset.expiration.rfc3339)
    cflt_managed_by      = "user"
    cflt_managed_id      = var.owner_email
  }
  cidr = cidrsubnet(var.vpcs_cidr_block, 2, 0) #vpcs_cidr_block is 10.3.0.0/16... returning a /18

  # Karpenter NodePool configuration - one pool per AZ
  karpenter_nodepools = {
    for idx, az in slice(data.aws_availability_zones.available.names, 0, 3) :
    "az${idx + 1}" => {
      name = "kafka-arm64-az${idx + 1}"
      zone = az
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Note: default_tags are removed to prevent "inconsistent plan" errors
}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================================================================
# 1. NETWORK (VPC 10.19.0.0/16)
# =============================================================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.17"

  name = "${var.project_name}-vpc"

  # The subnets defined below will automatically be carved out of this new /18 block
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  #we take the /16 and get only the /18
  cidr = local.cidr

  private_subnets = [
    cidrsubnet(local.cidr, 6, 1), # 10.19.1.0/24
    cidrsubnet(local.cidr, 6, 2), # 10.19.2.0/24
    cidrsubnet(local.cidr, 6, 3)  # 10.19.3.0/24
  ]
  public_subnets = [
    cidrsubnet(local.cidr, 6, 11), # 10.19.11.0/24
    cidrsubnet(local.cidr, 6, 12), # 10.19.12.0/24
    cidrsubnet(local.cidr, 6, 13)  # 10.19.13.0/24
  ]
  enable_nat_gateway   = true
  single_nat_gateway   = false # Use true for cost savings, false for HA
  enable_vpn_gateway   = false
  enable_dns_hostnames = true

  # CRITICAL FIX: Explicitly pass tags here because we removed default_tags
  tags = local.common_tags

  # Kubernetes Discovery Tags
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.project_name
  }

}


resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.project_name}-vpc-endpoints-"
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc.vpc_id # <--- FIXED: Uses the dynamic VPC ID

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.cidr] # <--- FIXED: Uses your local.cidr (10.19.0.0/18)
  }

  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpc-endpoints-sg"
  })
}


# =============================================================================
# 2. EKS CLUSTER
# =============================================================================

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = "${var.project_name}-cluster"
  addon_name                  = "vpc-cni"
  addon_version               = "v1.21.2-eksbuild.2"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = module.vpc_cni_irsa_role.iam_role_arn
}


resource "aws_eks_addon" "aws-ebs-csi-driver" {
  cluster_name                = "${var.project_name}-cluster"
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.60.0-eksbuild.1"
  service_account_role_arn    = module.ebs_csi_irsa_role.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    node = {
      tolerateAllTaints = true
    }
  })
  depends_on = [
    aws_vpc_endpoint.sts,
    aws_vpc_endpoint.ec2
  ]
}
resource "aws_eks_addon" "coredns" {
  cluster_name                = "${var.project_name}-cluster"
  addon_name                  = "coredns"
  addon_version               = "v1.14.2-eksbuild.4" # K8s 1.35 compatible
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}


resource "aws_eks_addon" "kube-proxy" {
  cluster_name                = "${var.project_name}-cluster"
  addon_name                  = "kube-proxy"
  addon_version               = "v1.35.3-eksbuild.8" # K8s 1.35 compatible
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.project_name}-cluster"
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access                   = true
  endpoint_private_access                  = true
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    karpenter_node = {
      principal_arn = aws_iam_role.karpenter_node.arn
      type          = "EC2_LINUX" # Grants system:node permissions
    }
  }

  node_security_group_additional_rules = {
    // allow all ingress traffic
    "all_ingress_from_jumpbox" = {
      description = "Allow all traffic from Jump Box SG"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0 # Matches your CLI command exactly
      type        = "ingress"

      # FIX: Use source_security_group_id instead of cidr_blocks
      source_security_group_id = aws_security_group.jump_box_sg.id
    }
  }

  addons = {

  }

  eks_managed_node_groups = {
    system_nodes = {
      name         = "${var.project_name}-system-v3"
      min_size     = 1
      max_size     = 2
      desired_size = 1

      instance_types = ["t3.large"]
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      # Provide a unique key (e.g., "critical") for the map element
      taints = {
        critical = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
      labels = {
        "workload"  = "system"
        "refresh"   = "v1"
        "node-type" = "system"
      }

      iam_role_additional_policies = {
        EKSCNIPolicy      = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        ECRReadOnlyPolicy = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        SSMMissingPolicy  = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }
  # end of eks managed NG


  tags = merge(
    local.common_tags,
    {
      "karpenter.sh/discovery"                            = var.project_name,
      "kubernetes.io/cluster/${var.project_name}-cluster" = "owned"
    }
  )
}

# =============================================================================
# 3. IAM ROLES (IRSA)
# =============================================================================

module "ebs_csi_irsa_role" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.52"
  role_name             = "${var.project_name}-ebs-csi"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "vpc_cni_irsa_role" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.52"
  role_name             = "${var.project_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name = "${var.project_name}-karpenter-node"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}


resource "aws_iam_role_policy_attachment" "karpenter_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])
  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.project_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

module "karpenter_controller_irsa" {
  source                                  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version                                 = "~> 5.52"
  role_name                               = "${var.project_name}-karpenter-controller"
  attach_karpenter_controller_policy      = true
  karpenter_controller_cluster_name       = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [aws_iam_role.karpenter_node.arn]

  role_policy_arns = {
    additional_permissions = aws_iam_policy.karpenter_controller_additional.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["karpenter:karpenter"]
    }
  }
}

resource "aws_iam_policy" "karpenter_controller_additional" {
  name        = "${var.project_name}-karpenter-controller-additional"
  description = "Additional permissions for Karpenter controller"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "iam:ListInstanceProfiles",
          "iam:GetInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "ec2:RunInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DeleteLaunchTemplate",
          "ec2:CreateTags",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:TerminateInstances",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ssm:GetParameter",
          "iam:PassRole"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# 4. KUBERNETES & HELM PROVIDERS
# =============================================================================

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
      command     = "aws"
    }
  }

}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
  load_config_file = false
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type = "gp3"
  }

  depends_on = [module.eks]
}

# =============================================================================
# 5. KARPENTER & OPERATOR INSTALLATION
# =============================================================================

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.12.1"
  namespace        = "karpenter"
  create_namespace = true
  depends_on       = [module.eks, aws_eks_addon.vpc_cni, aws_eks_addon.aws-ebs-csi-driver, aws_eks_addon.kube-proxy, aws_eks_addon.coredns]

  set = [
    {
      name  = "settings.clusterName"
      value = module.eks.cluster_name
    },
    {
      name  = "controller.resources.requests.cpu"
      value = "1"
    },
    {
      name  = "controller.resources.requests.memory"
      value = "1Gi"
    },
    {
      name  = "serviceAccount.create"
      value = "true"
    },
    {
      name  = "serviceAccount.name"
      value = "karpenter"
    },
    {
      name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = module.karpenter_controller_irsa.iam_role_arn
    },
    {
      name  = "settings.defaultInstanceProfile"
      value = aws_iam_instance_profile.karpenter_node.arn
    }
  ]
}

resource "helm_release" "confluent_operator" {
  name             = "confluent-operator"
  repository       = "https://packages.confluent.io/helm"
  chart            = "confluent-for-kubernetes"
  version          = "0.1514.40" # CFK 3.2.2 (latest as of 2026-04-30)
  namespace        = "confluent"
  create_namespace = true
  wait             = true
  values = [
    yamlencode({
      replicas = 2

      # Topology spread constraints for operator pods
      topologySpreadConstraints = [
        {
          maxSkew           = 1
          topologyKey       = "topology.kubernetes.io/zone"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "confluent-operator"
            }
          }
        },
        {
          maxSkew           = 1
          topologyKey       = "kubernetes.io/hostname"
          whenUnsatisfiable = "DoNotSchedule"
          labelSelector = {
            matchLabels = {
              "app.kubernetes.io/name" = "confluent-operator"
            }
          }
        }
      ]

      # Pod disruption budget for operator
      podDisruptionBudget = {
        enabled      = true
        minAvailable = 1
      },
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
          effect   = "NoSchedule"
        }
      ]
    })
  ]
  depends_on = [module.eks, helm_release.karpenter, kubernetes_storage_class_v1.gp3]
}

# =============================================================================
# 6. KARPENTER NODE POOLS
# =============================================================================

resource "kubectl_manifest" "kafka_nodeclass" {
  depends_on = [helm_release.karpenter]
  yaml_body = <<YAML
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: kafka-arm64  
  namespace: karpenter
spec:
  instanceProfile: ${aws_iam_instance_profile.karpenter_node.name}
  subnetSelectorTerms:
    - id: ${module.vpc.private_subnets[0]}
    - id: ${module.vpc.private_subnets[1]}
    - id: ${module.vpc.private_subnets[2]}
  securityGroupSelectorTerms:
    - id: ${module.eks.node_security_group_id}
  resources:
  
  amiSelectorTerms:
    - alias: al2023@latest
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["arm64"]  

  tags: ${jsonencode(merge(
  local.common_tags,
  {
    "karpenter.sh/discovery" = module.eks.cluster_name,
    "Name"                   = "${var.project_name}-karpenter-node"
  }
))}
  
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 50Gi
        volumeType: gp3
        deleteOnTermination: true
YAML
}


# Refactored: Single resource with for_each creates one NodePool per AZ
# This replaces the previous 3 duplicate resources, reducing code by 70%
resource "kubectl_manifest" "kafka_arm64_nodepool" {
  for_each = local.karpenter_nodepools

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = each.value.name
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "node-type"    = "kafka-arm64"
            "architecture" = "arm64"
          }
        }
        spec = {
          requirements = [
            { key = "topology.kubernetes.io/zone", operator = "In", values = [each.value.zone] },
            { key = "kubernetes.io/arch", operator = "In", values = ["arm64"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot"] }, # Spot-only for cost savings
            # Cheaper ARM64 instances, ordered by cost (cheapest first)
            { key = "node.kubernetes.io/instance-type", operator = "In", values = ["t4g.medium", "t4g.large", "t4g.xlarge", "t4g.2xlarge", "c6g.large", "c6g.xlarge", "c6g.2xlarge", "m6g.large", "m6g.xlarge", "m6g.2xlarge"] }
          ]
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "kafka-arm64"
          }
          taints = [
            { key = "arch", value = "arm64", effect = "NoSchedule" }
          ]
        }
      }
      limits = {
        cpu = 12000 # 12,000 vCPUs per AZ (enough for Kafka cluster workload)
      }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
      }
    }
  })
  depends_on = [helm_release.karpenter]
}


# =============================================================================
# 7. SECRETS
# =============================================================================

resource "random_uuid" "kafka_cluster_id" {}

resource "kubernetes_secret_v1" "kraft_cluster_id" {
  depends_on = [helm_release.confluent_operator]
  metadata {
    name      = "credential"
    namespace = "confluent"
  }
  data = {
    "cluster-id" = random_uuid.kafka_cluster_id.result
  }
}



# =============================================================================
# 8. VPC ENDPOINTS
# =============================================================================

# --- Interface Endpoints (STS, EC2, ECR) ---
# These run inside your private subnets and use the Security Group created above.

resource "aws_vpc_endpoint" "sts" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sts"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-sts"
  })
}

resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-ec2"
  })
}

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-ecr-api"
  })
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-ecr-dkr"
  })
}

# --- Gateway Endpoint (S3) ---
# Critical for pulling container layers from ECR reliably and cheaply.
# Uses Route Tables instead of ENIs/Security Groups.

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-vpce-s3"
  })
}

# =============================================================================
# 9. OUTPUT for the jumpbox
# =============================================================================





// These outputs are implicitly consumed by networking.tf
output "eks_worker_route_table_id" {
  description = "The route table ID for the EKS Worker Nodes."
  value       = module.vpc.private_route_table_ids[0]
}

output "eks_node_security_group_id" {
  description = "The security group ID used by the EKS Worker Nodes (Kafka Broker SG)."
  value       = module.eks.node_security_group_id
}

output "eks_vpc_cidr" {
  description = "the cidr block for networking.tf"
  value       = module.vpc.vpc_cidr_block
}

