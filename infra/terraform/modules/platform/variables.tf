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
  description = "Optional pre-baked AMI (Packer) with Platform Server prerequisites; null = the latest Windows Server 2022 at first apply, then pinned."
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

variable "server_profile" {
  description = "application = Platform Server farm hosting apps; lifetime = the LifeTime environment (LifeTime with Platform Server installer, no public app paths)."
  type        = string
  default     = "application"
  validation {
    condition     = contains(["application", "lifetime"], var.server_profile)
    error_message = "server_profile must be application or lifetime."
  }
}

variable "platform_server_version" {
  description = "Exact OutSystems release to install (e.g. 11.31.0). The installer must exist in the artifacts bucket under installers/. Pinned so every server in the farm, and every rebuild, runs the same build."
  type        = string
  validation {
    condition     = can(regex("^11\\.[0-9]+\\.[0-9]+$", var.platform_server_version))
    error_message = "platform_server_version must be an exact 11.x.y release, not latest."
  }
}

variable "platform_installer_key" {
  description = "Optional S3 key override for the installer; null = derived from server_profile and platform_server_version."
  type        = string
  default     = null
}

variable "app_path" {
  description = "Path of the main application, polled by new front-ends once a release has been deployed."
  type        = string
  default     = "/HomeScope/"
}

variable "public_path_patterns" {
  description = "ALB allowlist: only these paths reach the front-ends (max 5, case-sensitive). Everything else, including Service Center and LifeTime, gets a 404. Empty = nothing public (LifeTime)."
  type        = list(string)
  default     = ["/HomeScope", "/HomeScope/*", "/homescope", "/homescope/*", "/favicon.ico"]
  validation {
    condition     = length(var.public_path_patterns) <= 5
    error_message = "An ALB path_pattern condition accepts at most 5 values."
  }
}

variable "log_retention_days" {
  description = "Retention for the WAF log group."
  type        = number
  default     = 30
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
  description = "Front-end health check path: a static file the bootstrap writes once the server is configured, so app faults do not drain the farm."
  type        = string
  default     = "/health.html"
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
