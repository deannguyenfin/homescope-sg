variable "name" {
  description = "Name prefix for all resources."
  type        = string
}

variable "region" {
  description = "AWS region (used for VPC endpoint service names)."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block (/16 recommended)."
  type        = string
}

variable "az_count" {
  description = "Number of availability zones (2 or 3)."
  type        = number
  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3."
  }
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway for all AZs (cheaper, non-prod)."
  type        = bool
}

variable "flow_logs_bucket_arn" {
  description = "S3 bucket ARN for VPC flow logs; null disables flow logs."
  type        = string
  default     = null
}
