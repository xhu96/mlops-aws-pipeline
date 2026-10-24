output "url" {
  value = "${var.certificate_arn == null ? "http" : "https"}://${aws_lb.this.dns_name}"
}

output "alb_arn_suffix" {
  value = aws_lb.this.arn_suffix
}

output "target_group_arn_suffix" {
  value = aws_lb_target_group.this.arn_suffix
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_family" {
  value = aws_ecs_task_definition.this.family
}

output "log_group" {
  value = aws_cloudwatch_log_group.this.name
}
