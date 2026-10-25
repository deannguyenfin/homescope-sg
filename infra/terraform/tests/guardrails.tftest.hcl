# Plan-only tests with a mocked AWS provider: no credentials, no cost.
# Run: terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"] }
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
  environment                 = "dev"
  outsystems_environment_name = "Development"
  platform_server_version     = "11.33.0"
  allow_insecure_http         = true
  allowed_ingress_cidrs       = ["203.0.113.0/24"]
}

# A valid HTTP-only dev environment plans cleanly.
run "dev_http_only_from_known_network_is_allowed" {
  command = plan
}

run "dev_http_only_open_to_internet_is_rejected" {
  command = plan
  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [terraform_data.guardrails]
}

run "test_without_certificate_is_rejected" {
  command = plan
  variables {
    environment                 = "test"
    outsystems_environment_name = "Test"
  }
  expect_failures = [terraform_data.guardrails]
}

run "prod_with_placeholder_certificate_is_rejected" {
  command = plan
  variables {
    environment                 = "prod"
    outsystems_environment_name = "Production"
    allow_insecure_http         = false
    certificate_arn             = "arn:aws:acm:ap-southeast-1:123456789012:certificate/replace-me"
  }
  expect_failures = [terraform_data.guardrails]
}

run "lifetime_with_front_ends_is_rejected" {
  command = plan
  variables {
    environment                 = "lifetime"
    outsystems_environment_name = "LifeTime"
    frontend_min                = 1
    frontend_desired            = 1
    frontend_max                = 2
  }
  expect_failures = [terraform_data.guardrails]
}

run "half_configured_lifetime_peering_is_rejected" {
  command = plan
  variables {
    lifetime_vpc_id = "vpc-0123456789abcdef0"
  }
  expect_failures = [terraform_data.guardrails]
}

run "platform_version_must_be_pinned" {
  command = plan
  variables {
    platform_server_version = "latest"
  }
  expect_failures = [var.platform_server_version]
}

run "prod_without_high_availability_is_rejected" {
  command = plan
  variables {
    environment                 = "prod"
    outsystems_environment_name = "Production"
    allow_insecure_http         = false
    certificate_arn             = "arn:aws:acm:ap-southeast-1:123456789012:certificate/0b1c2d3e"
    db_multi_az                 = false
  }
  expect_failures = [terraform_data.guardrails]
}

run "prod_highly_available_plans_cleanly" {
  command = plan
  variables {
    environment                 = "prod"
    outsystems_environment_name = "Production"
    allow_insecure_http         = false
    allowed_ingress_cidrs       = ["0.0.0.0/0"]
    certificate_arn             = "arn:aws:acm:ap-southeast-1:123456789012:certificate/0b1c2d3e"
    az_count                    = 3
    single_nat_gateway          = false
    db_multi_az                 = true
    deletion_protection         = true
    frontend_min                = 2
    frontend_desired            = 2
    frontend_max                = 6
  }
}
