output "task_families" {
  value = { for k, td in aws_ecs_task_definition.this : k => td.family }
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}
