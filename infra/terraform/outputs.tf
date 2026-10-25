output "app_url" {
  description = "HomeScope entry point."
  value       = var.public_hostname != null ? "https://${var.public_hostname}/HomeScope/" : "http://${module.platform.alb_dns_name}/HomeScope/"
}

output "alb_dns_name" {
  value = module.platform.alb_dns_name
}

output "db_endpoint" {
  value = module.database.endpoint
}

output "controller_instance_id" {
  description = "Connect with: aws ssm start-session --target <id>"
  value       = module.platform.controller_instance_id
}

output "frontend_asg_name" {
  value = module.platform.frontend_asg_name
}

output "artifacts_bucket" {
  description = "Upload installers/PlatformServer-*.exe and the .NET hosting bundle here before first apply of the platform module."
  value       = aws_s3_bucket.artifacts.id
}

output "egress_ips" {
  value = module.network.nat_public_ips
}

output "alerts_topic_arn" {
  value = module.observability.alerts_topic_arn
}
