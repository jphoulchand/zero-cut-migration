# --- 1. VPC PEERING CONNECTION & ROUTES ---

locals {
  # 1. Retrieve the Service CIDR from the EKS cluster data source
  eks_service_cidr = module.eks.cluster_service_cidr

  # 2. Calculate the K8s DNS IP (always the 10th host in the service CIDR)
  k8s_dns_ip = cidrhost(local.eks_service_cidr, 10)
}

resource "aws_vpc_peering_connection" "jump_box_to_eks" {
  peer_vpc_id = module.vpc.vpc_id
  vpc_id      = aws_vpc.jump_box.id
  auto_accept = true

  tags = {
    Name = "${var.project_name}-jump-box-to-eks"
  }
}

# Route from Jump Box VPC to EKS VPC
resource "aws_route" "jump_box_to_eks" {
  # Target the custom route table associated with the Jump Box subnets.
  route_table_id = aws_route_table.jump_box_rt.id

  # Destination is the EKS VPC CIDR
  destination_cidr_block    = cidrsubnet(var.vpcs_cidr_block, 2, 0)
  vpc_peering_connection_id = aws_vpc_peering_connection.jump_box_to_eks.id
}

# Route the EKS Service CIDR (172.20.x.x) from the Jump Box VPC
resource "aws_route" "jump_box_to_eks_svc_cidr" {
  route_table_id = aws_route_table.jump_box_rt.id

  # Target the Kubernetes Service CIDR 
  destination_cidr_block    = local.eks_service_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.jump_box_to_eks.id
}

resource "aws_route" "jump_box_internet" {
  route_table_id         = aws_route_table.jump_box_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.jump_box_igw.id
}

# networking.tf

resource "aws_route" "eks_to_jump_box" {
  # This dynamically finds ALL private route tables created by your EKS VPC module
  count = length(module.vpc.private_route_table_ids)

  route_table_id = module.vpc.private_route_table_ids[count.index]

  # Target the entire Jump Box VPC CIDR (10.19.192.0/24)
  destination_cidr_block = aws_vpc.jump_box.cidr_block

  vpc_peering_connection_id = aws_vpc_peering_connection.jump_box_to_eks.id
}



