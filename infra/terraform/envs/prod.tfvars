environment                 = "prod"
outsystems_environment_name = "Production"
region                      = "ap-southeast-1"
vpc_cidr                    = "10.50.0.0/16"
az_count                    = 3
single_nat_gateway          = false

platform_server_version = "11.33.0" # same release as Test: promotion assumes identical platforms

controller_instance_type = "m6i.2xlarge"
frontend_instance_type   = "m6i.xlarge"
frontend_min             = 2
frontend_desired         = 2
frontend_max             = 6

db_engine                = "sqlserver-se"
db_instance_class        = "db.r6i.xlarge"
db_multi_az              = true
db_allocated_storage_gb  = 200
db_backup_retention_days = 30

certificate_arn = "arn:aws:acm:ap-southeast-1:111111111111:certificate/replace-me"
public_zone_id  = null
public_hostname = null

lifetime_vpc_id   = null # e.g. "vpc-xxxxxxxx" from the lifetime state
lifetime_vpc_cidr = null # e.g. "10.30.0.0/16"

alert_emails        = ["ops@example.com"]
log_retention_days  = 90
deletion_protection = true
