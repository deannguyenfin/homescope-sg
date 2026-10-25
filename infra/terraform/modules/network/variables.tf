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

variable "enable_flow_logs" {
  description = "Send rejected-traffic VPC flow logs to flow_logs_bucket_arn. A plain bool, so the resource count is known at plan time."
  type        = bool
  default     = true
}

variable "flow_logs_bucket_arn" {
  description = "S3 bucket ARN for VPC flow logs (required when enable_flow_logs = true)."
  type        = string
  default     = null
}
