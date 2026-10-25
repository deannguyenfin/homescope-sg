###############################################################################
# Platform: self-managed OutSystems 11 farm.
#   - 1 x Deployment Controller (compiler, Service Center, cache invalidation)
#   - N x Front-ends in an Auto Scaling Group behind an ALB (+ AWS WAF)
# Servers are Windows Server 2022, private subnets only, managed via SSM.
# Every server shares the same private.key and server.hsconf (rendered from
# Secrets Manager + this module), which is what lets the ASG add front-ends
# that self-register with the controller.
# server_profile = "lifetime" builds the same shape for the LifeTime
# environment (controller only, LifeTime installer, no public app paths).
###############################################################################

data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# The AMI is resolved once and then kept: a newer Windows AMI is never a
# surprise replacement on the next apply. Set ami_id (e.g. a Packer image) or
# `terraform apply -replace=module.platform.terraform_data.ami_pin` to move on.
resource "terraform_data" "ami_pin" {
  input            = coalesce(var.ami_id, data.aws_ssm_parameter.windows_ami.insecure_value)
  triggers_replace = [var.ami_id]
  lifecycle {
    ignore_changes = [input]
  }
}

locals {
  ami_id = terraform_data.ami_pin.output
  https  = var.certificate_arn != null
  installer_key = coalesce(var.platform_installer_key,
    var.server_profile == "lifetime"
    ? "installers/LifeTimeWithPlatformServer-${var.platform_server_version}.exe"
  : "installers/PlatformServer-${var.platform_server_version}.exe")
  # OutSystems inter-server ports: 12000 Deployment Controller service,
  # 12001 Deployment service, 12002 Scheduler, 12003 Server API, 5672 RabbitMQ
  # (cache invalidation, hosted on the controller).
  platform_ports = [
    { from = 12000, to = 12004, desc = "OutSystems platform services" },
    { from = 5672, to = 5672, desc = "Cache invalidation (RabbitMQ)" },
    { from = 80, to = 80, desc = "HTTP between servers" },
    { from = 443, to = 443, desc = "HTTPS between servers" },
  ]
  ready_parameter   = "/${var.name}/controller-ready"
  release_parameter = "/${var.name}/release"
}

#------------------------------------------------------------------ secrets ---

resource "random_password" "db" {
  for_each         = toset(["admin", "runtime", "log_admin", "log_runtime", "session", "platform_admin"])
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

# Everything a server needs to configure itself. The RDS master secret is NOT
# here: only the controller reads it, once, to create the OSADMIN login.
resource "aws_secretsmanager_secret" "platform" {
  name                    = "${var.name}/outsystems/platform"
  description             = "OutSystems DB logins and farm private.key"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "platform" {
  secret_id = aws_secretsmanager_secret.platform.id
  secret_string = jsonencode({
    admin_user              = "OSADMIN"
    admin_password          = random_password.db["admin"].result
    runtime_user            = "OSRUNTIME"
    runtime_password        = random_password.db["runtime"].result
    log_admin_user          = "OSLOGADMIN"
    log_admin_password      = random_password.db["log_admin"].result
    log_runtime_user        = "OSLOGRUNTIME"
    log_runtime_password    = random_password.db["log_runtime"].result
    session_user            = "OSSTATE"
    session_password        = random_password.db["session"].result
    platform_admin_password = random_password.db["platform_admin"].result
    private_key             = random_password.private_key.result
  })
}

# Written by the controller when it is fully configured; front-ends wait on it.
resource "aws_ssm_parameter" "controller_ready" {
  name        = local.ready_parameter
  description = "Set to a timestamp by the Deployment Controller bootstrap when the farm is ready for front-ends."
  type        = "String"
  value       = "pending"
  lifecycle {
    ignore_changes = [value]
  }
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
# Two roles: the controller may read the RDS master secret (once, to create
# OSADMIN) and signal readiness; front-ends get only the platform secret.

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
  for_each           = toset(["controller", "frontend"])
  name               = "${var.name}-outsystems-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = aws_iam_role.server
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  for_each   = aws_iam_role.server
  role       = each.value.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "common" {
  statement {
    sid       = "ReadInstallers"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.artifacts_bucket_arn, "${var.artifacts_bucket_arn}/installers/*", "${var.artifacts_bucket_arn}/config/*"]
  }
  statement {
    sid       = "ReadPlatformSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.platform.arn]
  }
  statement {
    sid       = "DecryptSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "controller" {
  source_policy_documents = [data.aws_iam_policy_document.common.json]
  statement {
    sid       = "ReadMasterSecretOnce"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_master_secret_arn]
  }
  statement {
    sid       = "SignalReady"
    actions   = ["ssm:PutParameter"]
    resources = [aws_ssm_parameter.controller_ready.arn]
  }
}

data "aws_iam_policy_document" "frontend" {
  source_policy_documents = [data.aws_iam_policy_document.common.json]
  statement {
    sid       = "ReadFarmState"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.name}/*"]
  }
  statement {
    sid       = "LifecycleHook"
    actions   = ["autoscaling:CompleteLifecycleAction"]
    resources = ["arn:aws:autoscaling:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:autoScalingGroup:*:autoScalingGroupName/${var.name}-frontend"]
  }
}

resource "aws_iam_role_policy" "server" {
  for_each = aws_iam_role.server
  role     = each.value.id
  policy   = each.key == "controller" ? data.aws_iam_policy_document.controller.json : data.aws_iam_policy_document.frontend.json
}

resource "aws_iam_instance_profile" "server" {
  for_each = aws_iam_role.server
  name     = "${var.name}-outsystems-${each.key}"
  role     = each.value.name
}

#----------------------------------------------------------------- bootstrap ---

locals {
  bootstrap_common = {
    region                  = data.aws_region.current.name
    artifacts_bucket        = var.artifacts_bucket_name
    platform_installer_key  = local.installer_key
    dotnet_hosting_key      = var.dotnet_hosting_installer_key
    platform_secret_arn     = aws_secretsmanager_secret.platform.arn
    db_host                 = var.db_address
    log_group_prefix        = var.log_group_prefix
    controller_private_dns  = "controller.${var.name}.internal"
    asg_name                = "${var.name}-frontend"
    lifecycle_hook_name     = "${var.name}-frontend-ready"
    environment_name        = var.environment_name
    server_profile          = var.server_profile
    ready_parameter         = local.ready_parameter
    release_parameter       = local.release_parameter
    app_path                = var.app_path
    outsystems_install_path = "D:\\OutSystems\\Platform Server"
  }
}

resource "aws_route53_zone" "internal" {
  name = "${var.name}.internal"
  vpc {
    vpc_id = var.vpc_id
  }
  # LifeTime's VPC is associated from the root module (aws_route53_zone_association).
  lifecycle {
    ignore_changes = [vpc]
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
  iam_instance_profile   = aws_iam_instance_profile.server["controller"].name
  monitoring             = true
  ebs_optimized          = true

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
    server_role          = "controller"
    db_master_secret_arn = var.db_master_secret_arn
  }))
  user_data_replace_on_change = false

  tags = { Name = "${var.name}-controller", Role = "deployment-controller" }

  # The controller is a pet (compiled apps, Service Center state, AWS Backup):
  # bootstrap edits apply to new servers only, never rebuild it in place.
  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [aws_iam_role_policy.server]
}

#---------------------------------------------------------------- front-ends ---

resource "aws_launch_template" "frontend" {
  name_prefix   = "${var.name}-frontend-"
  image_id      = local.ami_id
  instance_type = var.frontend_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.server["frontend"].arn
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
    server_role          = "frontend"
    db_master_secret_arn = ""
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
  # A first front-end can take ~1 h (controller install + app deploy); do not
  # block `terraform apply` on it. Readiness is gated by the lifecycle hook.
  wait_for_capacity_timeout = "0"

  launch_template {
    id      = aws_launch_template.frontend.id
    version = aws_launch_template.frontend.latest_version
  }

  # The bootstrap script completes this hook once the controller is ready and
  # the front-end serves its health file (and the app, after the first
  # release), so the ALB never routes to a half-configured server.
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

  depends_on = [aws_route53_record.controller, aws_iam_role_policy.server]
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
  idle_timeout               = 120
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

  # Platform-level check: a static file the bootstrap writes once the server
  # is configured. A broken or unpublished app must not drain the farm.
  health_check {
    path                = var.health_check_path
    matcher             = "200"
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
    type = local.https ? "redirect" : "fixed-response"

    dynamic "redirect" {
      for_each = local.https ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    dynamic "fixed_response" {
      for_each = local.https ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "Not found"
        status_code  = "404"
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

  # Allowlist: anything that is not a published app path (Service Center,
  # LifeTime, /servicecenter in any casing, other modules' APIs) gets a 404.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "app" {
  count        = length(var.public_path_patterns) > 0 ? 1 : 0
  listener_arn = local.https ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {
    path_pattern {
      values = var.public_path_patterns
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

# WAF requires the log group name to start with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Session cookies and auth headers never reach the logs.
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
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
