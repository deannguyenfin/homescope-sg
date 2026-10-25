environment                 = "dev"
outsystems_environment_name = "Development"
region                      = "ap-southeast-1"
vpc_cidr                    = "10.40.0.0/16"
az_count                    = 2
single_nat_gateway          = true

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

# certificate_arn = "arn:aws:acm:ap-southeast-1:<account>:certificate/<id>"
alert_emails        = []
deletion_protection = false
