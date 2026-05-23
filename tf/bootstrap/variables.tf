# =============================================================================
# BOOTSTRAP VARIABLES
# =============================================================================

variable "project_name" {
  description = "Project name used for resource naming (must match main terraform)"
  type        = string
  validation {
    condition     = length(var.project_name) > 0
    error_message = "project_name must not be empty"
  }
}

variable "aws_region" {
  description = "AWS region for S3 bucket and DynamoDB table (must match main terraform)"
  type        = string
  default     = "eu-west-1"
}
