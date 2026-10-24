# prod: serving only. Bundles are trained and gated in dev, then promoted here by
# the deploy workflow after manual approval. Two API tasks across two AZs.
module "stack" {
  source             = "../../modules/stack"
  environment        = "prod"
  region             = var.region
  github_repository  = "xhu96/mlops-aws-pipeline"
  vpc_cidr           = "10.20.0.0/16"
  ecr_registry       = var.ecr_registry
  api_image_tag      = var.api_image_tag
  trainer_image_tag  = var.trainer_image_tag
  mlflow_image_tag   = var.mlflow_image_tag
  model_version      = var.model_version
  enable_training    = false
  api_min_count      = 2
  api_max_count      = 6
  db_instance_class  = "db.t4g.small"
  protect_data       = true
  certificate_arn    = var.certificate_arn
  alert_emails       = var.alert_emails
  drift_schedule     = "cron(0 6 * * ? *)"
  log_retention_days = 90
}
