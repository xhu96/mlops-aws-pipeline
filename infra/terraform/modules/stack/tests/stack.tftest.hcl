# Offline wiring tests for the environment stack: `terraform test` in this directory.
# The AWS provider is mocked, so these run in CI without credentials and check
# the safety properties we care about before anything reaches a real account.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-2a", "eu-west-2b", "eu-west-2c"] }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:db", kms_key_id = "", secret_status = "active" }]
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = { arn_without_revision = "arn:aws:ecs:eu-west-2:123456789012:task-definition/churn" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/churn-mock" }
  }
}

variables {
  region            = "eu-west-2"
  github_repository = "xhu96/mlops-aws-pipeline"
  vpc_cidr          = "10.10.0.0/16"
  ecr_registry      = "123456789012.dkr.ecr.eu-west-2.amazonaws.com"
  api_image_tag     = "abc123"
  trainer_image_tag = "abc123"
  mlflow_image_tag  = "abc123"
  model_version     = "3"
  api_min_count     = 2
  api_max_count     = 4
  db_instance_class = "db.t4g.micro"
}

run "dev_stack_plans" {
  command = plan

  variables {
    environment     = "dev"
    protect_data    = false
    enable_training = true
  }

  assert {
    condition     = length(output.subnet_ids) == 2
    error_message = "Expected two subnets across two AZs"
  }
  assert {
    condition     = output.bundle_uri == "s3://churn-dev-models-123456789012/bundles"
    error_message = "Bundle URI must point at this environment's models bucket"
  }
  assert {
    condition     = keys(output.job_task_families) == ["drift", "retrain"]
    error_message = "Expected drift and retrain jobs"
  }
}

run "prod_stack_plans" {
  command = plan

  variables {
    environment     = "prod"
    protect_data    = true
    enable_training = false
    certificate_arn = "arn:aws:acm:eu-west-2:123456789012:certificate/abc"
  }

  assert {
    condition     = output.bundle_uri == "s3://churn-prod-models-123456789012/bundles"
    error_message = "prod must use its own models bucket"
  }
  assert {
    condition     = keys(output.job_task_families) == ["drift"]
    error_message = "prod must not train: only the drift job runs there"
  }
}

run "environment_is_validated" {
  command = plan

  variables {
    environment     = "staging"
    protect_data    = false
    enable_training = false
  }

  expect_failures = [var.environment]
}
