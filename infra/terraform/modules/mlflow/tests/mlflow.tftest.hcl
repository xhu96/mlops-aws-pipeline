# MLflow must stay private and its database must never be public.
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
  name                      = "churn-test"
  region                    = "eu-west-2"
  vpc_id                    = "vpc-123"
  subnet_ids                = ["subnet-a", "subnet-b"]
  cluster_arn               = "arn:aws:ecs:eu-west-2:123456789012:cluster/churn-test"
  namespace_id              = "ns-123"
  namespace_name            = "churn-test.internal"
  image                     = "mlflow:abc"
  execution_role_arn        = "arn:aws:iam::123456789012:role/exec"
  execution_role_name       = "exec"
  models_bucket             = "models"
  models_bucket_arn         = "arn:aws:s3:::models"
  client_security_group_ids = ["sg-jobs"]
}

run "database_is_private_and_encrypted" {
  command = plan

  assert {
    condition     = aws_db_instance.this.publicly_accessible == false && aws_db_instance.this.storage_encrypted
    error_message = "RDS must be private and encrypted"
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password
    error_message = "DB password must be managed by Secrets Manager, not Terraform"
  }
  assert {
    condition     = aws_db_instance.this.deletion_protection
    error_message = "Deletion protection should default to on"
  }
}

run "only_jobs_can_reach_mlflow" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.mlflow_from_clients) == 1
    error_message = "Exactly one ingress rule, from the jobs security group"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.mlflow_from_clients[0].referenced_security_group_id == "sg-jobs"
    error_message = "Ingress must reference the jobs security group, never a CIDR"
  }
}
