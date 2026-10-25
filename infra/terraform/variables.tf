variable "environment" {
  description = "Short environment key: dev | prod."
  type        = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "outsystems_environment_name" {
  description = "Environment name registered in LifeTime (Development / Production)."
  type        = string
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
