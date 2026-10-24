# One complete environment. envs/dev and envs/prod both call this module and
# differ only in sizing and safety settings, so the two can't drift apart.

data "aws_caller_identity" "current" {}

locals {
  name       = "churn-${var.environment}"
  namespace  = "${local.name}.internal"
  bundle_uri = "s3://${module.storage.models_bucket}/bundles"
}

module "network" {
  source = "../network"
  name   = local.name
  cidr   = var.vpc_cidr
  region = var.region
}

module "storage" {
  source        = "../storage"
  name          = local.name
  account_id    = data.aws_caller_identity.current.account_id
  force_destroy = !var.protect_data
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_service_discovery_private_dns_namespace" "this" {
  name = local.namespace
  vpc  = module.network.vpc_id
}

# Shared by all tasks: pull images from ECR and write logs.
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_security_group" "jobs" {
  name        = "${local.name}-jobs"
  description = "ML batch jobs: outbound only"
  vpc_id      = module.network.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Training (MLflow + retrain job) runs only where enable_training is set: dev is
# the ML workspace, prod only serves bundles promoted from dev. See docs/adr/0002.
module "mlflow" {
  count                     = var.enable_training ? 1 : 0
  source                    = "../mlflow"
  name                      = local.name
  region                    = var.region
  vpc_id                    = module.network.vpc_id
  subnet_ids                = module.network.public_subnet_ids
  cluster_arn               = aws_ecs_cluster.this.arn
  namespace_id              = aws_service_discovery_private_dns_namespace.this.id
  namespace_name            = local.namespace
  image                     = "${var.ecr_registry}/churn-mlflow:${var.mlflow_image_tag}"
  execution_role_arn        = aws_iam_role.execution.arn
  execution_role_name       = aws_iam_role.execution.name
  models_bucket             = module.storage.models_bucket
  models_bucket_arn         = module.storage.models_bucket_arn
  client_security_group_ids = [aws_security_group.jobs.id]
  db_instance_class         = var.db_instance_class
  deletion_protection       = var.protect_data
  log_retention_days        = var.log_retention_days
}

module "api" {
  source              = "../api_service"
  name                = local.name
  region              = var.region
  vpc_id              = module.network.vpc_id
  subnet_ids          = module.network.public_subnet_ids
  cluster_arn         = aws_ecs_cluster.this.arn
  cluster_name        = aws_ecs_cluster.this.name
  image               = "${var.ecr_registry}/churn-api:${var.api_image_tag}"
  execution_role_arn  = aws_iam_role.execution.arn
  capture_bucket      = module.storage.capture_bucket
  capture_bucket_arn  = module.storage.capture_bucket_arn
  models_bucket_arn   = module.storage.models_bucket_arn
  bundle_uri          = local.bundle_uri
  model_version       = var.model_version
  min_count           = var.api_min_count
  max_count           = var.api_max_count
  certificate_arn     = var.certificate_arn
  deletion_protection = var.protect_data
  log_retention_days  = var.log_retention_days
}

module "jobs" {
  source              = "../ml_jobs"
  name                = local.name
  region              = var.region
  cluster_arn         = aws_ecs_cluster.this.arn
  subnet_ids          = module.network.public_subnet_ids
  security_group_id   = aws_security_group.jobs.id
  image               = "${var.ecr_registry}/churn-trainer:${var.trainer_image_tag}"
  execution_role_arn  = aws_iam_role.execution.arn
  enable_training     = var.enable_training
  mlflow_tracking_uri = var.enable_training ? module.mlflow[0].tracking_uri : ""
  bundle_uri          = local.bundle_uri
  models_bucket       = module.storage.models_bucket
  models_bucket_arn   = module.storage.models_bucket_arn
  capture_bucket      = module.storage.capture_bucket
  capture_bucket_arn  = module.storage.capture_bucket_arn
  retrain_schedule    = var.retrain_schedule
  drift_schedule      = var.drift_schedule
  log_retention_days  = var.log_retention_days
}

module "monitoring" {
  source                  = "../monitoring"
  name                    = local.name
  region                  = var.region
  github_repository       = var.github_repository
  alert_emails            = var.alert_emails
  alb_arn_suffix          = module.api.alb_arn_suffix
  target_group_arn_suffix = module.api.target_group_arn_suffix
  cluster_arn             = aws_ecs_cluster.this.arn
  cluster_name            = aws_ecs_cluster.this.name
  api_service_name        = module.api.service_name
  api_log_group           = module.api.log_group
  job_task_families       = values(module.jobs.task_families)
}
