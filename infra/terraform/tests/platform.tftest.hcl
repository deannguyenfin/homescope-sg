# Security and availability properties of the OutSystems farm (mocked AWS: apply runs against mocks, nothing is created).

mock_provider "aws" {
  mock_resource "aws_lb" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:loadbalancer/app/x/1" }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:targetgroup/x/1" }
  }
  mock_resource "aws_lb_listener" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:listener/app/x/1/1" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:regional/webacl/x/1" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:log-group:x" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:role/x" }
  }
  mock_resource "aws_iam_instance_profile" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:instance-profile/x" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:secret:x" }
  }
  mock_resource "aws_ssm_parameter" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:parameter/x" }
  }
  mock_resource "aws_security_group" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:security-group/sg-1" }
  }
  mock_resource "aws_route53_zone" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:hostedzone/Z1" }
  }
  mock_resource "aws_launch_template" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:launch-template/lt-1", id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_autoscaling_group" {
    defaults = { arn = "arn:aws:service:ap-southeast-1:123456789012:autoScalingGroup:x" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "ap-southeast-1" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0", value = "ami-0123456789abcdef0" }
  }
}

variables {
  name                    = "homescope-test"
  environment_name        = "Test"
  vpc_id                  = "vpc-0123456789abcdef0"
  public_subnet_ids       = ["subnet-a", "subnet-b"]
  app_subnet_ids          = ["subnet-c", "subnet-d"]
  frontend_min            = 1
  frontend_max            = 2
  frontend_desired        = 1
  artifacts_bucket_name   = "artifacts"
  artifacts_bucket_arn    = "arn:aws:s3:::artifacts"
  logs_bucket_name        = "logs"
  platform_server_version = "11.33.0"
  db_address              = "db.internal"
  db_master_secret_arn    = "arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:rds-master-AbCdEf"
  kms_key_arn             = "arn:aws:kms:ap-southeast-1:123456789012:key/1"
  log_group_prefix        = "/homescope/test"
  certificate_arn         = "arn:aws:acm:ap-southeast-1:123456789012:certificate/1"
  deletion_protection     = false
}

run "application_farm" {
  command = apply
  module {
    source = "./modules/platform"
  }

  assert {
    condition = alltrue([
      for s in concat(tolist(data.aws_iam_policy_document.common.statement), tolist(data.aws_iam_policy_document.frontend.statement)) :
      !contains(tolist(s.resources), var.db_master_secret_arn)
    ])
    error_message = "Front-ends must not be able to read the RDS master secret."
  }
  assert {
    condition     = contains(flatten([for s in data.aws_iam_policy_document.controller.statement : tolist(s.resources)]), var.db_master_secret_arn)
    error_message = "The controller needs the master secret to create the dedicated OutSystems DB admin login."
  }
  assert {
    condition     = !strcontains(base64decode(aws_launch_template.frontend.user_data), var.db_master_secret_arn)
    error_message = "The master secret ARN must not reach front-end user data."
  }
  assert {
    condition     = aws_lb_target_group.frontend.health_check[0].path == "/health.html"
    error_message = "Health check must target the platform-level health file, not the app."
  }
  assert {
    condition     = length(aws_lb_listener_rule.app) == 1 && contains(tolist(aws_lb_listener_rule.app[0].condition)[0].path_pattern[0].values, "/HomeScope/*")
    error_message = "Only the allowlisted app paths are forwarded."
  }
  assert {
    condition     = one([for a in aws_lb_listener.https[0].default_action : a.fixed_response[0].status_code]) == "404"
    error_message = "Anything not allowlisted (Service Center, LifeTime, any casing) must get a 404."
  }
  assert {
    condition     = strcontains(aws_instance.controller.user_data, "installers/PlatformServer-11.33.0.exe")
    error_message = "The installer is pinned to platform_server_version."
  }
}
