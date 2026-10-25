variable "environment" {
  description = "Short environment key: lifetime | dev | test | prod. Each has its own VPC and state."
  type        = string
  validation {
    condition     = contains(["lifetime", "dev", "test", "prod"], var.environment)
    error_message = "environment must be lifetime, dev, test or prod."
  }
}

variable "outsystems_environment_name" {
  description = "Environment name registered in LifeTime (LifeTime / Development / Test / Production)."
  type        = string
}

variable "platform_server_version" {
  description = "Exact OutSystems 11 release installed on every server (the licensed installer must be in the artifacts bucket)."
  type        = string
  validation {
    condition     = can(regex("^11[.][0-9]+[.][0-9]+$", var.platform_server_version))
    error_message = "platform_server_version must be an exact 11.x.y release, not latest."
  }
}

variable "lifetime_vpc_id" {
  description = "VPC of the LifeTime environment. When set (dev/test/prod), the VPCs are peered so LifeTime can manage this environment privately."
  type        = string
  default     = null
}

variable "lifetime_vpc_cidr" {
  description = "CIDR of the LifeTime VPC (required with lifetime_vpc_id)."
  type        = string
  default     = null
}

variable "allow_insecure_http" {
  description = "Explicit opt-in to an HTTP-only ALB (no certificate). Only allowed for dev; test and prod must have certificate_arn."
  type        = bool
  default     = false
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "az_count" {
  type    = number
  default = 2
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "allowed_ingress_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "controller_instance_type" {
  type    = string
  default = "m6i.xlarge"
}

variable "frontend_instance_type" {
  type    = string
  default = "m6i.large"
}

variable "frontend_min" {
  type    = number
  default = 1
}

variable "frontend_max" {
  type    = number
  default = 2
}

variable "frontend_desired" {
  type    = number
  default = 1
}

variable "db_engine" {
  type    = string
  default = "sqlserver-se"
}

variable "db_instance_class" {
  type    = string
  default = "db.m6i.large"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 100
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "public_zone_id" {
  type    = string
  default = null
}

variable "public_hostname" {
  type    = string
  default = null
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "log_bucket_retention_days" {
  type    = number
  default = 365
}

variable "deletion_protection" {
  type    = bool
  default = false
}
