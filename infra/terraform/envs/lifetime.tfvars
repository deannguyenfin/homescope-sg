# LifeTime: the environment that manages Dev, Test and Prod (deployment
# plans, version tags, users). Controller only, no public app paths: the
# console is reached privately (SSM port forwarding / VPN), never via the ALB.
environment                 = "lifetime"
outsystems_environment_name = "LifeTime"
region                      = "ap-southeast-1"
vpc_cidr                    = "10.30.0.0/16"
az_count                    = 2
single_nat_gateway          = true

platform_server_version = "11.33.0" # LifeTime with Platform Server, same major as the farms

controller_instance_type = "m6i.xlarge"
frontend_instance_type   = "m6i.large"
frontend_min             = 0
frontend_desired         = 0
frontend_max             = 0

db_engine                = "sqlserver-se"
db_instance_class        = "db.m6i.large"
db_multi_az              = false
db_allocated_storage_gb  = 100
db_backup_retention_days = 14

alert_emails        = ["ops@example.com"]
deletion_protection = true
