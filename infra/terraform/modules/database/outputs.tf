output "endpoint" {
  description = "host:port of the SQL Server instance."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "instance_id" {
  value = aws_db_instance.this.identifier
}

output "master_secret_arn" {
  description = "Secrets Manager secret (RDS-managed, rotated) holding the master credentials."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "kms_key_arn" {
  value = aws_kms_key.db.arn
}

output "security_group_id" {
  value = aws_security_group.db.id
}
