# =============================================================================
# DNS RESOLUTION VIA NODEPORT
# =============================================================================
# This file creates a NodePort service that exposes the kube-dns service
# to the jumpbox VPC via the system nodes, eliminating the need for:
#   - Manual DNS IP updates (CoreDNS pod IPs can change)
#   - NLB cost (~$16/month)
#
# Architecture:
#   Jumpbox -> System Node IPs:30053 -> kube-dns NodePort -> CoreDNS pods
#
# Benefits:
#   - Free (no NLB cost)
#   - Stable (system node IPs don't change)
#   - Simple (direct NodePort access)
#
# The system nodes are in the EKS VPC, accessible via VPC peering.
# =============================================================================

# -----------------------------------------------------------------------------
# 1. Expose kube-dns via NodePort
# -----------------------------------------------------------------------------

resource "kubernetes_service_v1" "kube_dns_external" {
  metadata {
    name      = "kube-dns-external"
    namespace = "kube-system"
  }

  spec {
    type = "NodePort"

    # Target the existing kube-dns service
    selector = {
      "k8s-app" = "kube-dns"
    }

    # DNS over UDP
    port {
      name        = "dns-udp"
      port        = 53
      target_port = 53
      protocol    = "UDP"
      node_port   = 30053
    }

    # DNS over TCP (for larger responses)
    port {
      name        = "dns-tcp"
      port        = 53
      target_port = 53
      protocol    = "TCP"
      node_port   = 30053
    }

    session_affinity = "None"
  }

  depends_on = [
    module.eks,
    aws_eks_addon.coredns
  ]
}

# -----------------------------------------------------------------------------
# 2. Get system node IPs for jumpbox DNS configuration
# -----------------------------------------------------------------------------

data "aws_instances" "system_nodes" {
  instance_tags = {
    "karpenter.sh/nodepool" = ""  # System nodes don't have this tag
    "alpha.eksctl.io/cluster-name" = ""  # System nodes don't have this either
  }

  filter {
    name   = "tag:eks:cluster-name"
    values = [module.eks.cluster_name]
  }

  filter {
    name   = "tag:eks:nodegroup-name"
    values = ["system_nodes"]
  }

  filter {
    name   = "instance-state-name"
    values = ["running"]
  }

  depends_on = [module.eks]
}

# Get private IPs of system nodes
data "aws_instance" "system_nodes" {
  count = length(data.aws_instances.system_nodes.ids)

  instance_id = data.aws_instances.system_nodes.ids[count.index]
}

# -----------------------------------------------------------------------------
# 3. Outputs
# -----------------------------------------------------------------------------

# System node IPs for DNS (space-separated for systemd-resolved)
locals {
  system_node_ips = join(" ", [for instance in data.aws_instance.system_nodes : instance.private_ip])
}

output "kube_dns_node_ips" {
  description = "System node IPs for kube-dns access via NodePort 30053"
  value       = local.system_node_ips
}

output "kube_dns_nodeport_info" {
  description = "Instructions for DNS configuration"
  value = <<-EOT

    ╔════════════════════════════════════════════════════════════════╗
    ║           DNS CONFIGURATION VIA NODEPORT                        ║
    ╚════════════════════════════════════════════════════════════════╝

    System Node IPs: ${local.system_node_ips}
    NodePort: 30053 (UDP/TCP)

    The jumpbox is configured to use these IPs on port 30053 for DNS.

    To verify DNS resolution from jumpbox:
      ssh ${var.ssh_user}@<jumpbox-ip>
      resolvectl status
      dig @${element(split(" ", local.system_node_ips), 0)} -p 30053 kafka.confluent.svc.cluster.local +short

    Benefits:
      - No NLB cost (saves ~$16/month)
      - Stable IPs (system nodes persist)
      - Simple architecture

  EOT
}
