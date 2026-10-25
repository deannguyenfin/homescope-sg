###############################################################################
# Database: Amazon RDS for SQL Server hosting the OutSystems platform +
# application catalogs (outsystems), the logging catalog (outsystems_log) and
# the session catalog (outsystems_session). The OutSystems Configuration Tool
# creates the catalogs and the runtime/log/session logins on first install
# using the master credentials stored in Secrets Manager.
###############################################################################

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-sql"
  subnet_ids = var.data_subnet_ids
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "SQL Server - ingress added by root module (OutSystems servers only)"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.name}-db" }
}

resource "aws_kms_key" "db" {
  description             = "${var.name} RDS storage + Performance Insights"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-rds"
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name}-sqlserver"
  family = var.parameter_group_family

  # Encrypt client connections (OutSystems connection strings use Encrypt=True).
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

# Native backup/restore to S3: used to seed environments and for off-RDS backups.
resource "aws_db_option_group" "this" {
  name                 = "${var.name}-sqlserver"
  engine_name          = var.engine
  major_engine_version = var.major_engine_version

  option {
    option_name = "SQLSERVER_BACKUP_RESTORE"
    option_settings {
      name  = "IAM_ROLE_ARN"
      value = aws_iam_role.native_backup.arn
    }
  }
}

data "aws_iam_policy_document" "rds_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "native_backup" {
  name               = "${var.name}-rds-native-backup"
  assume_role_policy = data.aws_iam_policy_document.rds_assume.json
}

data "aws_iam_policy_document" "native_backup" {
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [var.backup_bucket_arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"]
    resources = ["${var.backup_bucket_arn}/rds/*"]
  }
}

resource "aws_iam_role_policy" "native_backup" {
  role   = aws_iam_role.native_backup.id
  policy = data.aws_iam_policy_document.native_backup.json
}

resource "aws_iam_role" "monitoring" {
  name = "${var.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  role       = aws_iam_role.monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-sql"
  engine         = var.engine
  engine_version = var.engine_version
  license_model  = "license-included"
  instance_class = var.instance_class
  multi_az       = var.multi_az
  timezone       = var.timezone

  allocated_storage     = var.allocated_storage_gb
  max_allocated_storage = var.max_allocated_storage_gb
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  username                      = var.master_username
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  option_group_name      = aws_db_option_group.this.name
  publicly_accessible    = false
  port                   = 1433

  backup_retention_period   = var.backup_retention_days
  backup_window             = "17:00-18:00" # 01:00-02:00 SGT, before the 02:00 sync timer
  maintenance_window        = "sun:18:30-sun:19:30"
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name}-sql-final" : null

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.db.arn
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.monitoring.arn
  enabled_cloudwatch_logs_exports       = ["error", "agent"]

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = { Name = "${var.name}-sql" }
}
