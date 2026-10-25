output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.frontend.arn_suffix
}

output "server_security_group_id" {
  value = aws_security_group.servers.id
}

output "controller_instance_id" {
  value = aws_instance.controller.id
}

output "frontend_asg_name" {
  value = aws_autoscaling_group.frontend.name
}

output "platform_secret_arn" {
  value = aws_secretsmanager_secret.platform.arn
}

output "waf_acl_arn" {
  value = aws_wafv2_web_acl.this.arn
}

output "controller_ready_parameter" {
  value = aws_ssm_parameter.controller_ready.name
}

output "release_parameter" {
  description = "Written by the deploy workflow after the first promotion; new front-ends then also wait for the app itself."
  value       = local.release_parameter
}

output "internal_zone_id" {
  value = aws_route53_zone.internal.zone_id
}
