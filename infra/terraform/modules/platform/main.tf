###############################################################################
# Platform: self-managed OutSystems 11 farm.
#   - 1 x Deployment Controller (compiler, Service Center, cache invalidation)
#   - N x Front-ends in an Auto Scaling Group behind an ALB (+ AWS WAF)
# Servers are Windows Server 2022, private subnets only, managed via SSM.
# Every server shares the same private.key and server.hsconf (rendered from
# Secrets Manager + this module), which is what lets the ASG add front-ends
# that self-register with the controller.
###############################################################################

data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ami_id = coalesce(var.ami_id, data.aws_ssm_parameter.windows_ami.value)
  https  = var.certificate_arn != null
  # OutSystems inter-server ports: 12000 Deployment Controller service,
  # 12001 Deployment service, 12002 Scheduler, 12003 Server API, 5672 RabbitMQ
  # (cache invalidation, hosted on the controller).
  platform_ports = [
    { from = 12000, to = 12004, desc = "OutSystems platform services" },
    { from = 5672, to = 5672, desc = "Cache invalidation (RabbitMQ)" },
    { from = 80, to = 80, desc = "HTTP between servers" },
    { from = 443, to = 443, desc = "HTTPS between servers" },
  ]
}

#------------------------------------------------------------------ secrets ---

resource "random_password" "db" {
  for_each         = toset(["runtime", "log_admin", "log_runtime", "session"])
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "random_password" "private_key" {
  # OutSystems private.key: shared symmetric key used to encrypt settings and
  # sign tokens; must be identical on every server in the farm.
  length  = 64
  special = false
}

resource "aws_secretsmanager_secret" "platform" {
  name                    = "${var.name}/outsystems/platform"
  description             = "OutSystems DB logins and farm private.key"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "platform" {
  secret_id = aws_secretsmanager_secret.platform.id
  secret_string = jsonencode({
    runtime_user         = "OSRUNTIME"
    runtime_password     = random_password.db["runtime"].result
    log_admin_user       = "OSLOGADMIN"
    log_admin_password   = random_password.db["log_admin"].result
    log_runtime_user     = "OSLOGRUNTIME"
    log_runtime_password = random_password.db["log_runtime"].result
    session_user         = "OSSTATE"
    session_password     = random_password.db["session"].result
    private_key          = random_password.private_key.result
  })
}

#----------------------------------------------------------- security groups ---

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Public ALB for OutSystems front-ends"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each          = toset(var.allowed_ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "HTTP (redirected to HTTPS when a certificate is set)"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_servers" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.servers.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "To front-ends"
}

resource "aws_security_group" "servers" {
  name        = "${var.name}-servers"
  description = "OutSystems Deployment Controller and front-ends"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-servers" }
}

resource "aws_vpc_security_group_ingress_rule" "servers_from_alb" {
  security_group_id            = aws_security_group.servers.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP from ALB (TLS terminates at the ALB)"
}

resource "aws_vpc_security_group_ingress_rule" "servers_intra" {
  for_each                     = { for p in local.platform_ports : "${p.from}-${p.to}" => p }
  security_group_id            = aws_security_group.servers.id
  referenced_security_group_id = aws_security_group.servers.id
  from_port                    = each.value.from
  to_port                      = each.value.to
  ip_protocol                  = "tcp"
  description                  = each.value.desc
}

resource "aws_vpc_security_group_egress_rule" "servers_all" {
  security_group_id = aws_security_group.servers.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound (DB, NAT to data.gov.sg / licensing, VPC endpoints)"
}

#----------------------------------------------------------------------- IAM ---

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "server" {
  name               = "${var.name}-outsystems-server"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.server.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "server" {
  statement {
    sid       = "ReadInstallers"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.artifacts_bucket_arn, "${var.artifacts_bucket_arn}/installers/*", "${var.artifacts_bucket_arn}/config/*"]
  }
  statement {
    sid       = "ReadSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.platform.arn, var.db_master_secret_arn]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
  statement {
    sid       = "LifecycleHook"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["arn:aws:autoscaling:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name}-frontend"]
  }
}

resource "aws_iam_role_policy" "server" {
  role   = aws_iam_role.server.id
  policy = data.aws_iam_policy_document.server.json
}

resource "aws_iam_instance_profile" "server" {
  name = "${var.name}-outsystems-server"
  role = aws_iam_role.server.name
}

#----------------------------------------------------------------- bootstrap ---

locals {
  bootstrap_common = {
    region                  = data.aws_region.current.name
    artifacts_bucket        = var.artifacts_bucket_name
    platform_installer_key  = var.platform_installer_key
    dotnet_hosting_key      = var.dotnet_hosting_installer_key
    platform_secret_arn     = aws_secretsmanager_secret.platform.arn
    db_master_secret_arn    = var.db_master_secret_arn
    db_host                 = var.db_address
    log_group_prefix        = var.log_group_prefix
    controller_private_dns  = "controller.${var.name}.internal"
    asg_name                = "${var.name}-frontend"
    lifecycle_hook_name     = "${var.name}-frontend-ready"
    environment_name        = var.environment_name
    outsystems_install_path = "D:\\OutSystems\\Platform Server"
  }
}

resource "aws_route53_zone" "internal" {
  name = "${var.name}.internal"
  vpc {
    vpc_id = var.vpc_id
  }
}

resource "aws_route53_record" "controller" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "controller.${var.name}.internal"
  type    = "A"
  ttl     = 60
  records = [aws_instance.controller.private_ip]
}

#--------------------------------------------------------- deployment controller

resource "aws_instance" "controller" {
  ami                    = local.ami_id
  instance_type          = var.controller_instance_type
  subnet_id              = var.app_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.servers.id]
  iam_instance_profile   = aws_iam_instance_profile.server.name
  monitoring             = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 80
    encrypted   = true
  }

  ebs_block_device {
    device_name = "xvdb" # D:\ - OutSystems install, compiled apps, logs
    volume_type = "gp3"
    volume_size = var.data_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.ps1.tftpl", merge(local.bootstrap_common, {
    server_role = "controller"
  }))
  user_data_replace_on_change = false

  tags = { Name = "${var.name}-controller", Role = "deployment-controller" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

#---------------------------------------------------------------- front-ends ---

resource "aws_launch_template" "frontend" {
  name_prefix   = "${var.name}-frontend-"
  image_id      = local.ami_id
  instance_type = var.frontend_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.server.arn
  }

  vpc_security_group_ids = [aws_security_group.servers.id]

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  monitoring {
    enabled = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type = "gp3"
      volume_size = 80
      encrypted   = true
    }
  }

  block_device_mappings {
    device_name = "xvdb"
    ebs {
      volume_type = "gp3"
      volume_size = var.data_volume_gb
      encrypted   = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/bootstrap.ps1.tftpl", merge(local.bootstrap_common, {
    server_role = "frontend"
  })))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-frontend", Role = "frontend" }
  }
}

resource "aws_autoscaling_group" "frontend" {
  name                      = "${var.name}-frontend"
  min_size                  = var.frontend_min
  max_size                  = var.frontend_max
  desired_capacity          = var.frontend_desired
  vpc_zone_identifier       = var.app_subnet_ids
  target_group_arns         = [aws_lb_target_group.frontend.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 1800 # Platform Server install + first deploy
  default_instance_warmup   = 600

  launch_template {
    id      = aws_launch_template.frontend.id
    version = aws_launch_template.frontend.latest_version
  }

  # The bootstrap script completes this hook once the front-end has received
  # all applications from the Deployment Controller, so the ALB never routes
  # to a half-deployed server.
  initial_lifecycle_hook {
    name                 = "${var.name}-frontend-ready"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    default_result       = "ABANDON"
    heartbeat_timeout    = 3600
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 600
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-frontend"
    propagate_at_launch = true
  }

  depends_on = [aws_route53_record.controller]
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-frontend-cpu"
  autoscaling_group_name = aws_autoscaling_group.frontend.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.frontend_cpu_target
  }
}

#----------------------------------------------------------------------- ALB ---

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  idle_timeout               = 120 # long-running Service Center / timer UI requests
  enable_deletion_protection = var.deletion_protection

  access_logs {
    bucket  = var.logs_bucket_name
    prefix  = "alb"
    enabled = true
  }
}

resource "aws_lb_target_group" "frontend" {
  name                 = "${var.name}-fe"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = 60

  health_check {
    path                = var.health_check_path
    matcher             = "200-399"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = local.https ? "redirect" : "forward"
    target_group_arn = local.https ? null : aws_lb_target_group.frontend.arn

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

# Platform consoles are internal-only: block them on the public listener.
resource "aws_lb_listener_rule" "block_consoles" {
  listener_arn = local.https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 10

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }

  condition {
    path_pattern {
      values = ["/ServiceCenter*", "/LifeTime*", "/ServiceStudio*"]
    }
  }
}

#----------------------------------------------------------------------- WAF ---

resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesAmazonIpReputationList = 1
      AWSManagedRulesCommonRuleSet          = 2
      AWSManagedRulesKnownBadInputsRuleSet  = 3
      AWSManagedRulesSQLiRuleSet            = 4
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
          # OutSystems Reactive screen actions post JSON bodies > 8 KB.
          dynamic "rule_action_override" {
            for_each = rule.key == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

#------------------------------------------------------------------ public DNS

resource "aws_route53_record" "public" {
  count   = var.public_zone_id == null ? 0 : 1
  zone_id = var.public_zone_id
  name    = var.public_hostname
  type    = "A"
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
