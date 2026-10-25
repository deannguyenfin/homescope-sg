# Test (QA / UAT): production-like topology (2 front-ends behind the ALB, TLS),
# smaller and single-AZ for the database to keep cost down.
environment                 = "test"
outsystems_environment_name = "Test"
region                      = "ap-southeast-1"
vpc_cidr                    = "10.45.0.0/16"
az_count                    = 2
single_nat_gateway          = true

platform_server_version = "11.33.0" # same release as Production: promotion assumes identical platforms

controller_instance_type = "m6i.xlarge"
frontend_instance_type   = "m6i.large"
frontend_min             = 1
frontend_desired         = 2
frontend_max             = 2

db_engine                = "sqlserver-se"
db_instance_class        = "db.m6i.large"
db_multi_az              = false
db_allocated_storage_gb  = 100
db_backup_retention_days = 7

certificate_arn = "arn:aws:acm:ap-southeast-1:111111111111:certificate/replace-me"
public_zone_id  = null
public_hostname = null

lifetime_vpc_id   = null # e.g. "vpc-xxxxxxxx" from the lifetime state
lifetime_vpc_cidr = null # e.g. "10.30.0.0/16"

alert_emails        = ["ops@example.com"]
log_retention_days  = 30
deletion_protection = false
