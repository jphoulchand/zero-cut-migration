# --- LOCALS ---

locals {
  # Base name for all resources in this file
  base_name = "${var.project_name}-jump"


  # 1. Calculates the /24 block for the Jump Box VPC (e.g., 10.3.192.0/24)
  jumpbox_cidr_block = cidrsubnet(var.vpcs_cidr_block, 8, 192)

  # 2. Calculates the smaller /27 subnets inside the /24 block
  #    (8 + 3 = 11 new bits, resulting in a /27 subnet size)
  #    CORRECTION: When calculating subnets from the result of another cidrsubnet,
  #    the 'newbits' argument should be the difference in prefix length.
  #    If jumpbox_cidr_subnet is /24, and you want /27, the newbits is 3.
  jump_box_subnet_cidr_1 = cidrsubnet(local.jumpbox_cidr_block, 3, 0)
  jump_box_subnet_cidr_2 = cidrsubnet(local.jumpbox_cidr_block, 3, 1)

  # Fetch a second AZ
  second_az = data.aws_availability_zones.available.names[1]
}

# --- 1. JUMP BOX VPC AND SUBNET (/24 and /27) ---

resource "aws_vpc" "jump_box" {
  cidr_block = local.jumpbox_cidr_block

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-vpc"
  })
}



resource "aws_subnet" "jump_box_public_subnet_1" {
  vpc_id                  = aws_vpc.jump_box.id
  cidr_block              = local.jump_box_subnet_cidr_1
  map_public_ip_on_launch = true
  availability_zone       = var.jump_box_availability_zone

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-Public-Subnet-1"
  })
}

resource "aws_subnet" "jump_box_public_subnet_2" {
  vpc_id                  = aws_vpc.jump_box.id
  cidr_block              = local.jump_box_subnet_cidr_2
  map_public_ip_on_launch = true
  availability_zone       = local.second_az

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-Public-Subnet-2"
  })
}



# --- 2. INTERNET GATEWAY AND ROUTE TABLE ---

# 1. Internet Gateway (IGW)
resource "aws_internet_gateway" "jump_box_igw" {
  vpc_id = aws_vpc.jump_box.id
  tags   = merge(local.common_tags, { Name = "${var.project_name}-jump-box-igw" })
}

# 2. Dedicated Route Table
resource "aws_route_table" "jump_box_rt" {
  vpc_id = aws_vpc.jump_box.id
  tags   = merge(local.common_tags, { Name = "${var.project_name}-jump-box-rt" })
}

# 3. Routes (The routes themselves are defined in networking.tf)
# NOTE: The route to the EKS VPC (aws_route.jump_box_to_eks) and the internet
# route (aws_route.jump_box_to_internet) must be defined in networking.tf 
# to avoid conflicts and correctly use the VPC Peering Connection resource.


# 4. FIX: Route Table Associations (RTA) for both subnets
# This links the subnets to the custom route table (aws_route_table.jump_box_rt)

# RTA for Subnet 1
resource "aws_route_table_association" "jump_box_public_rta_1" {
  subnet_id      = aws_subnet.jump_box_public_subnet_1.id
  route_table_id = aws_route_table.jump_box_rt.id

}

# RTA for Subnet 2
resource "aws_route_table_association" "jump_box_public_rta_2" {
  subnet_id      = aws_subnet.jump_box_public_subnet_2.id
  route_table_id = aws_route_table.jump_box_rt.id

}

# --- 3. JUMP BOX SECURITY GROUP ---

resource "aws_security_group" "jump_box_sg" {
  name        = "${local.base_name}-SG"
  vpc_id      = aws_vpc.jump_box.id
  description = "Allows SSH access to the Jump Box for project ${var.project_name}"

  # Ingress: SSH access (restricted to allowed IPs only)
  ingress {
    description = "SSH from allowed CIDR blocks (VPN, office, etc.)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Egress: All outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow ALL traffic from EKS VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"         # All protocols (TCP/UDP/ICMP)
    cidr_blocks = [local.cidr] # Uses the /18 CIDR defined in main.tf
  }

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-SG"
  })
}


# --- 4. IAM ROLE FOR JUMP BOX ---

# IAM role for jumpbox EC2 instance
resource "aws_iam_role" "jump_box_role" {
  name = "${local.base_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-role"
  })
}

# IAM policy for EKS cluster access
resource "aws_iam_role_policy" "jump_box_eks_policy" {
  name = "${local.base_name}-eks-policy"
  role = aws_iam_role.jump_box_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      }
    ]
  })
}

# Instance profile for jumpbox
resource "aws_iam_instance_profile" "jump_box_profile" {
  name = "${local.base_name}-profile"
  role = aws_iam_role.jump_box_role.name

  tags = merge(local.common_tags, {
    Name = "${local.base_name}-profile"
  })
}


# --- 5. JUMP BOX EC2 INSTANCE ---

# Find the latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Look up the existing Key Pair by name
data "aws_key_pair" "existing_jump_box_key" {
  key_name = var.ssh_key_name
}

resource "aws_instance" "jump_box" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.jump_box_profile.name
  # Launch into the first public subnet
  subnet_id                   = aws_subnet.jump_box_public_subnet_1.id
  vpc_security_group_ids      = [aws_security_group.jump_box_sg.id]
  key_name                    = data.aws_key_pair.existing_jump_box_key.key_name
  associate_public_ip_address = true # Needed since EIP is associated later

  # Configure DNS to use system nodes via NodePort for cluster.local resolution
  # Note: On first apply, system_node_ips may be "pending" - DNS setup will need manual update
  user_data = local.system_node_ips != "pending" ? base64encode(templatefile("${path.module}/scripts/setup_dns.sh", {
    system_node_ips = local.system_node_ips
  })) : base64encode("#!/bin/bash\necho 'DNS setup pending - run terraform output kube_dns_node_ips after apply'")

  lifecycle {
    ignore_changes = [
      user_data,
    ]
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 100
    encrypted             = true
    delete_on_termination = true
  }
  tags = merge(local.common_tags, {
    Name = local.base_name
  })
}


output "jump_box_setup_commands" {
  description = "Manual commands required to provision the Jump Box after SSHing in."
  value       = <<-EOT
    #####################################################################
    ### JUMP BOX SETUP COMMANDS
    #####################################################################

    If jumpbox was recreated, remove old SSH host key:
      ssh-keygen -R ${aws_eip.jump_box_eip.public_ip}

    1. Upload install_binaries.sh to jumpbox:
       scp -i ${var.ssh_private_key_path} \
         scripts/install_binaries.sh \
         ${var.ssh_user}@${aws_eip.jump_box_eip.public_ip}:~/

    2. SSH into the Jump Box:
       ssh -i ${var.ssh_private_key_path} ${var.ssh_user}@${aws_eip.jump_box_eip.public_ip}

    3. Run the installation script (on jumpbox):
       chmod +x install_binaries.sh
       ./install_binaries.sh

    4. Verify DNS resolution (after install completes):
       resolvectl status
       dig kafka.confluent.svc.cluster.local +short

    Note: install_binaries.sh installs kubectl, helm, Kafka CLI tools, and AWS CLI.
          This is run manually (not in Terraform) to avoid jumpbox recreation on updates.

    EOT
}

# --- 6. ELASTIC IP (Static Public IP for SSH) ---

resource "aws_eip" "jump_box_eip" {
  tags = merge(local.common_tags, {
    Name = "${local.base_name}-EIP"
  })
}

resource "aws_eip_association" "jump_box_eip_assoc" {
  instance_id   = aws_instance.jump_box.id
  allocation_id = aws_eip.jump_box_eip.id

}

# --- 7. OUTPUTS ---

output "jump_box_role_arn" {
  description = "The ARN of the Jump Box IAM role (for EKS aws-auth ConfigMap)."
  value       = aws_iam_role.jump_box_role.arn
}

output "jump_box_vpc_id" {
  description = "The ID of the newly created Jump Box VPC (for peering)."
  value       = aws_vpc.jump_box.id
}


output "jump_box_public_ip" {
  description = "The static public IP address for SSH access."
  value       = aws_eip.jump_box_eip.public_ip
}

output "jump_box_public_subnet_ids" {
  description = "The list of public subnet IDs (for Route53 Resolver Endpoint)."
  value       = [aws_subnet.jump_box_public_subnet_1.id, aws_subnet.jump_box_public_subnet_2.id]
}
