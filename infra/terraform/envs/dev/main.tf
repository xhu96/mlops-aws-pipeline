# dev: the ML workspace. Smallest sizes, MLflow + weekly retraining, no deletion
# protection, plain HTTP allowed.
module "stack" {
  source             = "../../modules/stack"
  environment        = "dev"
  region             = var.region
  github_repository  = "xhu96/mlops-aws-pipeline"
  vpc_cidr           = "10.10.0.0/16"
  ecr_registry       = var.ecr_registry
  api_image_tag      = var.api_image_tag
  trainer_image_tag  = var.trainer_image_tag
  mlflow_image_tag   = var.mlflow_image_tag
  model_version      = var.model_version
  enable_training    = true
  api_min_count      = 1
  api_max_count      = 2
  db_instance_class  = "db.t4g.micro"
  protect_data       = false
  certificate_arn    = var.certificate_arn
  alert_emails       = var.alert_emails
  drift_schedule     = "cron(0 6 * * ? *)"
  retrain_schedule   = null # weekly retraining is driven by .github/workflows/retrain.yml
  log_retention_days = 7
}
