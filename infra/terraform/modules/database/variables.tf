variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "data_subnet_ids" {
  type = list(string)
}

variable "backup_bucket_arn" {
  description = "Bucket used by SQLSERVER_BACKUP_RESTORE (prefix rds/)."
  type        = string
}

variable "engine" {
  description = "sqlserver-se (Standard) or sqlserver-ee (Enterprise)."
  type        = string
  default     = "sqlserver-se"
}

variable "engine_version" {
  description = "SQL Server engine version (OutSystems 11 supports SQL Server 2016+)."
  type        = string
  default     = "16.00.4135.4.v1"
}

variable "major_engine_version" {
  type    = string
  default = "16.00"
}

variable "parameter_group_family" {
  type    = string
  default = "sqlserver-se-16.0"
}

variable "instance_class" {
  type = string
}

variable "multi_az" {
  type = bool
}

variable "timezone" {
  description = "SQL Server time zone; OutSystems stores DateTime in server time."
  type        = string
  default     = "Singapore Standard Time"
}

variable "allocated_storage_gb" {
  type    = number
  default = 100
}

variable "max_allocated_storage_gb" {
  type    = number
  default = 500
}

variable "master_username" {
  type    = string
  default = "osadmin"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type = bool
}
