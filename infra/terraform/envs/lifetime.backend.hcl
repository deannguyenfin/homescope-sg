bucket         = "homescope-tfstate-<account-id>"
key            = "homescope/lifetime/terraform.tfstate"
region         = "ap-southeast-1"
dynamodb_table = "homescope-tflock"
encrypt        = true
