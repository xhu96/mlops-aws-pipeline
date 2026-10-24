output "tracking_uri" {
  value = "http://mlflow.${var.namespace_name}:5000"
}

output "security_group_id" {
  value = aws_security_group.mlflow.id
}
