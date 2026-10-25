variable "name" {
  type = string
}

variable "environment_name" {
  description = "OutSystems environment name shown in Service Center / LifeTime (e.g. Development, Production)."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "app_subnet_ids" {
  type = list(string)
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the public ALB."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ami_id" {
  description = "Optional pre-baked AMI (Packer) with Platform Server prerequisites; null = latest Windows Server 2022."
  type        = string
  default     = null
}

variable "controller_instance_type" {
  type    = string
  default = "m6i.xlarge"
}

variable "frontend_instance_type" {
  type    = string
  default = "m6i.large"
}

variable "data_volume_gb" {
  type    = number
  default = 100
}

variable "frontend_min" {
  type = number
}

variable "frontend_max" {
  type = number
}

variable "frontend_desired" {
  type = number
}

variable "frontend_cpu_target" {
  description = "Target average CPU % for front-end scaling."
  type        = number
  default     = 60
}

variable "artifacts_bucket_name" {
  type = string
}

variable "artifacts_bucket_arn" {
  type = string
}

variable "logs_bucket_name" {
  type = string
}

variable "platform_installer_key" {
  description = "S3 key of the OutSystems Platform Server installer (licensed, uploaded manually)."
  type        = string
  default     = "installers/PlatformServer-11.latest.exe"
}

variable "dotnet_hosting_installer_key" {
  description = "S3 key of the .NET Hosting Bundle required by Platform Server."
  type        = string
  default     = "installers/dotnet-hosting-8.0-win.exe"
}

variable "db_address" {
  type = string
}

variable "db_master_secret_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "log_group_prefix" {
  type = string
}

variable "certificate_arn" {
  description = "ACM certificate for the HTTPS listener; null = HTTP only (sandbox use)."
  type        = string
  default     = null
}

variable "health_check_path" {
  description = "Front-end health check path (a lightweight anonymous screen or REST endpoint)."
  type        = string
  default     = "/HomeScope/"
}

variable "waf_rate_limit_per_5min" {
  type    = number
  default = 2000
}

variable "public_zone_id" {
  type    = string
  default = null
}

variable "public_hostname" {
  type    = string
  default = null
}

variable "deletion_protection" {
  type = bool
}
