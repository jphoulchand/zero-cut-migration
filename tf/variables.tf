variable "project_name" {
  description = "Short project identifier (6-7 chars)."
  type        = string
  validation {
    condition     = length(var.project_name) > 0
    error_message = "'project_name' must not be empty. Please provide a unique project identifier."
  }
}

variable "owner_email" {
  description = "Owner email address — used for tagging and cflt_managed_id."
  type        = string
  validation {
    condition     = length(var.owner_email) > 0
    error_message = "'owner_email' must not be empty. Please provide your email address."
  }
}

variable "aws_region" {
  description = "The AWS region to deploy the EKS cluster and related resources."
  type        = string
  default     = "eu-west-1"
}



variable "kubernetes_version" {
  description = "Kubernetes version. REQUIRED to prevent Node Group module crash. NOTE: EKS only allows one minor version upgrade at a time (e.g., 1.33→1.34→1.35)."
  type        = string
  default     = "1.35"
}


# --- VARIABLES ---


variable "vpcs_cidr_block" {
  description = "The reserved /16 CIDR block for the Jump Box VPC and EKS VPC. for example: 10.3.0.0/16"
  type        = string
  validation {
    condition     = length(var.vpcs_cidr_block) > 0
    error_message = "'vpcs_cidr_block' must not be empty. Please provide a /16 CIDR block (e.g. 10.3.0.0/16)."
  }
}
variable "jump_box_availability_zone" {
  description = "The AZ where the Jump Box VPC subnet will be created (e.g., eu-west-1a)."
  type        = string
}
variable "ssh_key_name" {
  description = "The name of the key pair to create in AWS."
  type        = string
}
variable "ssh_private_key_path" {
  description = "Local path to your existing private SSH key."
  type        = string
}

variable "instance_type" {
  description = "The size of the Jump Box EC2 instance."
  type        = string
  default     = "t3.large"
}

variable "ssh_user" {
  description = "The username used to SSH into the Jump Box (e.g., 'ec2-user' for Amazon Linux or 'ubuntu' for Ubuntu)."
  type        = string
  default     = "ec2-user"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to the jumpbox. Specify your IP or office network (e.g., ['203.0.113.42/32']). This replaces the previous 0.0.0.0/0 open access for security."
  type        = list(string)
  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "allowed_ssh_cidrs must contain at least one CIDR block. Provide your IP address (e.g., ['YOUR.IP.ADDRESS/32'])."
  }
}