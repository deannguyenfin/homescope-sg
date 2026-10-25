###############################################################################
# One-time bootstrap (local state): remote-state bucket, lock table and the
# GitHub Actions OIDC roles (plan, deploy) used by the CI/CD workflows. Run once per account:
#   terraform -chdir=infra/terraform/bootstrap init
#   terraform -chdir=infra/terraform/bootstrap apply -var github_repo=<org>/homescope-sg
###############################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "github_repo" {
  description = "GitHub repository allowed to assume the deploy role (owner/name)."
  type        = string
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket = "homescope-tfstate-${data.aws_caller_identity.current.account_id}"
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Keep 90 days of previous state versions for recovery, then expire them.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "state-history"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = "homescope-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Two roles, each trusted only from named GitHub environments of this repo
# (no branch or wildcard subjects, so a workflow on any other ref cannot assume them):
#   homescope-github-plan    <- environments <env>-plan   (read-only + state lock)
#   homescope-github-deploy  <- environments <env>        (reviewers required for test, prod, lifetime)
locals {
  environments = ["lifetime", "dev", "test", "prod"]
  oidc_subjects = {
    plan   = [for e in local.environments : "repo:${var.github_repo}:environment:${e}-plan"]
    deploy = [for e in local.environments : "repo:${var.github_repo}:environment:${e}"]
  }
}

data "aws_iam_policy_document" "github_assume" {
  for_each = local.oidc_subjects
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = local.oidc_subjects
  name                 = "homescope-github-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.github_assume[each.key].json
  max_session_duration = 3600
}

# --- plan: read everything, write only the state lock -------------------------
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.github["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "plan" {
  statement {
    sid       = "State"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
  }
  statement {
    sid       = "Lock"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.lock.arn]
  }
  statement {
    sid       = "RefreshSecretVersions"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:homescope-*"]
  }
  statement {
    sid       = "DecryptHomeScopeKeys"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "ForAnyValue:StringLike"
      variable = "kms:ResourceAliases"
      values   = ["alias/homescope-*"]
    }
  }
}

resource "aws_iam_role_policy" "plan" {
  role   = aws_iam_role.github["plan"].id
  policy = data.aws_iam_policy_document.plan.json
}

# --- deploy: PowerUser for the services in this repo, IAM only on homescope-* --
resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  role       = aws_iam_role.github["deploy"].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "deploy_iam" {
  statement {
    sid = "ManageHomeScopeIam"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/homescope-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/homescope-*",
    ]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*"]
  }
  statement {
    sid       = "NoSelfEscalation"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [for r in aws_iam_role.github : r.arn]
  }
}

resource "aws_iam_role_policy" "deploy_iam" {
  role   = aws_iam_role.github["deploy"].id
  policy = data.aws_iam_policy_document.deploy_iam.json
}

output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.lock.name
}

output "github_plan_role_arn" {
  value = aws_iam_role.github["plan"].arn
}

output "github_deploy_role_arn" {
  value = aws_iam_role.github["deploy"].arn
}
