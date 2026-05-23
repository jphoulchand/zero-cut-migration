# =============================================================================
# TERRAFORM STATE BACKEND BOOTSTRAP
# =============================================================================
# This file creates the S3 bucket and DynamoDB table needed for remote state.
#
# IMPORTANT: This must be deployed FIRST, before the main terraform.
# The bootstrap itself uses local state (stored in this directory).
#
# Usage:
#   cd bootstrap/
#   terraform init
#   terraform apply
#   # Note the bucket and table names from outputs
#   cd ..
#   # Uncomment backend block in versions.tf
#   terraform init -migrate-state
# =============================================================================

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# 1. S3 Bucket for Terraform State
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "terraform_state" {
  bucket = "${var.project_name}-terraform-state"

  tags = {
    Name        = "${var.project_name}-terraform-state"
    Purpose     = "Terraform remote state storage"
    ManagedBy   = "Terraform Bootstrap"
    Environment = "Shared"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Enable versioning for state file recovery
resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state files at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access to state bucket
resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy to clean up old versions (optional)
resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# -----------------------------------------------------------------------------
# 2. DynamoDB Table for State Locking
# -----------------------------------------------------------------------------

resource "aws_dynamodb_table" "terraform_locks" {
  name         = "${var.project_name}-terraform-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "${var.project_name}-terraform-locks"
    Purpose     = "Terraform state locking"
    ManagedBy   = "Terraform Bootstrap"
    Environment = "Shared"
  }

  lifecycle {
    prevent_destroy = true
  }
}
