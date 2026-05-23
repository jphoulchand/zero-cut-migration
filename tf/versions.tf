terraform {
  required_version = ">= 1.7.0"

  # REMOTE STATE BACKEND (commented until bootstrap is deployed)
  # Uncomment after running: cd bootstrap/ && terraform apply
  # Then run: terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket         = "jph-demo-terraform-state"  # Update with your project_name
  #   key            = "terraform.tfstate"
  #   region         = "eu-west-1"                  # Update with your aws_region
  #   encrypt        = true
  #   dynamodb_table = "jph-demo-terraform-locks"  # Update with your project_name
  # }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.46" # Latest: 6.46.0
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1" # Latest: 3.1.2
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.1" # Latest: 3.1.0
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.19.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}
