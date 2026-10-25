variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "log_group_prefix" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "db_instance_id" {
  type = string
}

variable "controller_instance_id" {
  type = string
}

variable "frontend_asg_name" {
  type = string
}

variable "has_frontends" {
  description = "false for the LifeTime environment (no front-end farm): ALB and farm alarms are not created."
  type        = bool
  default     = true
}
