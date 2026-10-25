###############################################################################
# HomeScope SG - self-managed OutSystems 11 environment on AWS.
# One root module, one state per environment:
#   lifetime -> dev -> test -> prod   (envs/<env>.tfvars + envs/<env>.backend.hcl)
# The LifeTime environment is applied first; the others peer to its VPC.
###############################################################################

locals {
  name             = "homescope-${var.environment}"
  log_group_prefix = "/homescope/${var.environment}"
  is_lifetime      = var.environment == "lifetime"
  peer_lifetime    = var.lifetime_vpc_id != null && var.lifetime_vpc_cidr != null
}

# Plan-time guardrails: misconfigurations fail before anything is created.
resource "terraform_data" "guardrails" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = var.certificate_arn != null || local.is_lifetime || (var.environment == "dev" && var.allow_insecure_http)
      error_message = "test and prod need certificate_arn. Only dev may run HTTP-only, and only with allow_insecure_http = true."
    }
    precondition {
      condition     = var.certificate_arn == null || !can(regex("replace-me", var.certificate_arn))
      error_message = "certificate_arn is still the placeholder from the example tfvars."
    }
    precondition {
      condition     = !(var.environment == "dev" && var.allow_insecure_http) || !contains(var.allowed_ingress_cidrs, "0.0.0.0/0")
      error_message = "An HTTP-only dev environment must restrict allowed_ingress_cidrs (no 0.0.0.0/0)."
    }
    precondition {
      condition     = (var.lifetime_vpc_id == null) == (var.lifetime_vpc_cidr == null)
      error_message = "Set lifetime_vpc_id and lifetime_vpc_cidr together."
    }
    precondition {
      condition     = !local.is_lifetime || (var.frontend_max == 0 && var.lifetime_vpc_id == null)
      error_message = "The LifeTime environment has no front-ends (frontend_* = 0) and does not peer to itself."
    }
    precondition {
      condition     = var.environment != "prod" || (var.db_multi_az && var.deletion_protection && var.az_count >= 2 && !var.single_nat_gateway)
      error_message = "prod must be highly available: db_multi_az, deletion_protection, az_count >= 2 and a NAT gateway per AZ."
    }
  }
}

data "aws_caller_identity" "current" {}

#------------------------------------------------------------------- storage ---

# Installers (licensed Platform Server binaries), rendered config, DB backups.
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"
  force_destroy = !var.deletion_protection
}

# ALB access logs + VPC flow logs.
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = { artifacts = aws_s3_bucket.artifacts.id, logs = aws_s3_bucket.logs.id }
  bucket                  = each.value
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Installers are versioned: keep superseded versions 180 days for rollback.
resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "superseded-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 180
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

# ALB access logging only supports SSE-S3 on the target bucket.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = var.log_bucket_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AlbAccessLogs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
  statement {
    sid       = "FlowLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }
  statement {
    sid       = "FlowLogsAcl"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json
}

# server.hsconf template consumed by the bootstrap script on every server.
resource "aws_s3_object" "hsconf_template" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "config/server.hsconf.template"
  source = "${path.module}/config/server.hsconf.template"
  etag   = filemd5("${path.module}/config/server.hsconf.template")
}

#------------------------------------------------------------------- modules ---

module "network" {
  source               = "./modules/network"
  name                 = local.name
  region               = var.region
  vpc_cidr             = var.vpc_cidr
  az_count             = var.az_count
  single_nat_gateway   = var.single_nat_gateway
  enable_flow_logs     = true
  flow_logs_bucket_arn = aws_s3_bucket.logs.arn
}

module "database" {
  source                 = "./modules/database"
  name                   = local.name
  vpc_id                 = module.network.vpc_id
  data_subnet_ids        = module.network.data_subnet_ids
  backup_bucket_arn      = aws_s3_bucket.artifacts.arn
  instance_class         = var.db_instance_class
  multi_az               = var.db_multi_az
  allocated_storage_gb   = var.db_allocated_storage_gb
  backup_retention_days  = var.db_backup_retention_days
  deletion_protection    = var.deletion_protection
  engine                 = var.db_engine
  parameter_group_family = "${var.db_engine}-16.0"
}

module "platform" {
  source                   = "./modules/platform"
  name                     = local.name
  environment_name         = var.outsystems_environment_name
  server_profile           = local.is_lifetime ? "lifetime" : "application"
  platform_server_version  = var.platform_server_version
  public_path_patterns     = local.is_lifetime ? [] : ["/HomeScope", "/HomeScope/*", "/homescope", "/homescope/*", "/favicon.ico"]
  log_retention_days       = var.log_retention_days
  vpc_id                   = module.network.vpc_id
  public_subnet_ids        = module.network.public_subnet_ids
  app_subnet_ids           = module.network.app_subnet_ids
  allowed_ingress_cidrs    = var.allowed_ingress_cidrs
  controller_instance_type = var.controller_instance_type
  frontend_instance_type   = var.frontend_instance_type
  frontend_min             = var.frontend_min
  frontend_max             = var.frontend_max
  frontend_desired         = var.frontend_desired
  artifacts_bucket_name    = aws_s3_bucket.artifacts.id
  artifacts_bucket_arn     = aws_s3_bucket.artifacts.arn
  logs_bucket_name         = aws_s3_bucket.logs.id
  db_address               = module.database.address
  db_master_secret_arn     = module.database.master_secret_arn
  kms_key_arn              = module.database.kms_key_arn
  log_group_prefix         = local.log_group_prefix
  certificate_arn          = var.certificate_arn
  public_zone_id           = var.public_zone_id
  public_hostname          = var.public_hostname
  deletion_protection      = var.deletion_protection

  depends_on = [aws_s3_bucket_policy.logs, aws_s3_object.hsconf_template, terraform_data.guardrails]
}

resource "aws_vpc_security_group_ingress_rule" "db_from_platform" {
  security_group_id            = module.database.security_group_id
  referenced_security_group_id = module.platform.server_security_group_id
  from_port                    = 1433
  to_port                      = 1433
  ip_protocol                  = "tcp"
  description                  = "SQL Server from OutSystems servers"
}

#------------------------------------------------- LifeTime VPC peering -------
# LifeTime manages each environment through its Deployment Controller over
# HTTP(S). Peering keeps that traffic private; the consoles stay off the ALB.

resource "aws_vpc_peering_connection" "lifetime" {
  count       = local.peer_lifetime ? 1 : 0
  vpc_id      = module.network.vpc_id
  peer_vpc_id = var.lifetime_vpc_id
  auto_accept = true # same account and region
  tags        = { Name = "${local.name}-to-lifetime" }
}

resource "aws_route" "to_lifetime" {
  for_each                  = local.peer_lifetime ? { for i, id in module.network.private_route_table_ids : tostring(i) => id } : {}
  route_table_id            = each.value
  destination_cidr_block    = var.lifetime_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.lifetime[0].id
}

data "aws_route_tables" "lifetime" {
  count  = local.peer_lifetime ? 1 : 0
  vpc_id = var.lifetime_vpc_id
  filter {
    name   = "tag:Name"
    values = ["homescope-lifetime-app-*", "homescope-lifetime-data"]
  }
}

resource "aws_route" "from_lifetime" {
  for_each                  = local.peer_lifetime ? toset(data.aws_route_tables.lifetime[0].ids) : toset([])
  route_table_id            = each.value
  destination_cidr_block    = var.vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.lifetime[0].id
}

resource "aws_vpc_security_group_ingress_rule" "servers_from_lifetime" {
  for_each          = local.peer_lifetime ? toset(["80", "443"]) : toset([])
  security_group_id = module.platform.server_security_group_id
  cidr_ipv4         = var.lifetime_vpc_cidr
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  ip_protocol       = "tcp"
  description       = "LifeTime environment management"
}

# LifeTime resolves controller.<env>.internal through the private zone.
resource "aws_route53_zone_association" "lifetime" {
  count   = local.peer_lifetime ? 1 : 0
  zone_id = module.platform.internal_zone_id
  vpc_id  = var.lifetime_vpc_id
}

module "observability" {
  source                  = "./modules/observability"
  name                    = local.name
  region                  = var.region
  log_group_prefix        = local.log_group_prefix
  log_retention_days      = var.log_retention_days
  alert_emails            = var.alert_emails
  alb_arn_suffix          = module.platform.alb_arn_suffix
  target_group_arn_suffix = module.platform.target_group_arn_suffix
  db_instance_id          = module.database.instance_id
  controller_instance_id  = module.platform.controller_instance_id
  frontend_asg_name       = module.platform.frontend_asg_name
  has_frontends           = !local.is_lifetime
}

#---------------------------------------------------- backups (AWS Backup) ---

resource "aws_backup_vault" "this" {
  name        = "${local.name}-vault"
  kms_key_arn = module.database.kms_key_arn
}

resource "aws_backup_plan" "this" {
  name = "${local.name}-daily"
  rule {
    rule_name         = "daily-35d"
    target_vault_name = aws_backup_vault.this.name
    schedule          = "cron(0 16 * * ? *)" # 00:00 SGT
    lifecycle {
      delete_after = 35
    }
  }
}

resource "aws_iam_role" "backup" {
  name = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Controller holds compiled apps + Service Center config; front-ends are cattle.
resource "aws_backup_selection" "controller" {
  name         = "${local.name}-controller"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/${module.platform.controller_instance_id}"]
}
