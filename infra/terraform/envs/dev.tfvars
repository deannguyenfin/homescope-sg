environment                 = "dev"
outsystems_environment_name = "Development"
region                      = "ap-southeast-1"
vpc_cidr                    = "10.40.0.0/16"
az_count                    = 2
single_nat_gateway          = true

platform_server_version = "11.33.0" # exact release uploaded to s3://<artifacts>/installers/

controller_instance_type = "m6i.xlarge"
frontend_instance_type   = "m6i.large"
frontend_min             = 1
frontend_desired         = 1
frontend_max             = 2

db_engine                = "sqlserver-se"
db_instance_class        = "db.m6i.large"
db_multi_az              = false
db_allocated_storage_gb  = 100
db_backup_retention_days = 7

# Dev may run HTTP-only, but then only from known networks (guardrail in main.tf).
allow_insecure_http   = true
allowed_ingress_cidrs = ["203.0.113.0/24"] # replace with the office / VPN egress range
# certificate_arn = "arn:aws:acm:ap-southeast-1:<account>:certificate/<id>"

# Peer to the LifeTime environment (apply envs/lifetime.tfvars first):
# lifetime_vpc_id   = "vpc-xxxxxxxx"
# lifetime_vpc_cidr = "10.30.0.0/16"
alert_emails        = []
deletion_protection = false
