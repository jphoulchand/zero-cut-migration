# =============================================================================
# BOOTSTRAP OUTPUTS
# =============================================================================
# These outputs provide the configuration needed for the main terraform backend.
# =============================================================================

output "s3_bucket_name" {
  description = "S3 bucket name for terraform state"
  value       = aws_s3_bucket.terraform_state.id
}

output "dynamodb_table_name" {
  description = "DynamoDB table name for state locking"
  value       = aws_dynamodb_table.terraform_locks.name
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "backend_configuration" {
  description = "Backend configuration block for main terraform versions.tf"
  value = <<-EOT

    ╔════════════════════════════════════════════════════════════════╗
    ║          BACKEND BOOTSTRAP COMPLETE                             ║
    ╚════════════════════════════════════════════════════════════════╝

    Add this to your main terraform versions.tf:

    terraform {
      backend "s3" {
        bucket         = "${aws_s3_bucket.terraform_state.id}"
        key            = "terraform.tfstate"
        region         = "${var.aws_region}"
        encrypt        = true
        dynamodb_table = "${aws_dynamodb_table.terraform_locks.name}"
      }
    }

    Then run:
      cd ..
      terraform init -migrate-state

  EOT
}
