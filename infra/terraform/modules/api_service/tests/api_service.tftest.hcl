# The API must roll back failed deploys and only accept traffic from the ALB.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:db", kms_key_id = "", secret_status = "active" }]
    }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/churn-mock" }
  }
}

variables {
  name               = "churn-test"
  region             = "eu-west-2"
  vpc_id             = "vpc-123"
  subnet_ids         = ["subnet-a", "subnet-b"]
  cluster_arn        = "arn:aws:ecs:eu-west-2:123456789012:cluster/churn-test"
  cluster_name       = "churn-test"
  image              = "api:abc"
  execution_role_arn = "arn:aws:iam::123456789012:role/exec"
  capture_bucket     = "capture"
  capture_bucket_arn = "arn:aws:s3:::capture"
  models_bucket_arn  = "arn:aws:s3:::models"
  bundle_uri         = "s3://models/bundles"
  model_version      = "3"
}

run "safe_deployments" {
  command = plan

  assert {
    condition     = aws_ecs_service.this.deployment_circuit_breaker[0].rollback
    error_message = "Failed deployments must roll back automatically"
  }
  assert {
    condition     = aws_ecs_service.this.deployment_minimum_healthy_percent == 100
    error_message = "Rolling deploys must keep full capacity"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].readonlyRootFilesystem
    error_message = "API container must run with a read-only root filesystem"
  }
  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].environment, { name = "MODEL_VERSION", value = "3" })
    error_message = "Task definition must pin the model version"
  }
  assert {
    condition     = aws_lb_target_group.this.health_check[0].path == "/health"
    error_message = "ALB must health-check /health"
  }
}

run "http_only_without_certificate" {
  command = plan

  assert {
    condition     = length(aws_lb_listener.https) == 0
    error_message = "No HTTPS listener without a certificate"
  }
}

run "https_redirect_with_certificate" {
  command = plan

  variables {
    certificate_arn = "arn:aws:acm:eu-west-2:123456789012:certificate/abc"
  }

  assert {
    condition     = aws_lb_listener.http.default_action[0].type == "redirect"
    error_message = "HTTP must redirect to HTTPS when a certificate is set"
  }
  assert {
    condition     = length(aws_lb_listener.https) == 1
    error_message = "HTTPS listener expected"
  }
}
