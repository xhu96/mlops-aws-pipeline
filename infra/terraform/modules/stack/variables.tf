variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod"
  }
}

variable "region" {
  type = string
}

variable "github_repository" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "ecr_registry" {
  description = "<account>.dkr.ecr.<region>.amazonaws.com"
  type        = string
}

variable "api_image_tag" {
  type = string
}

variable "trainer_image_tag" {
  type = string
}

variable "mlflow_image_tag" {
  type = string
}

variable "enable_training" {
  description = "Run MLflow and the retrain job in this environment"
  type        = bool
}

variable "model_version" {
  description = "Model bundle version the API serves (set by CI from champion.json)"
  type        = string
}

variable "api_min_count" {
  type = number
}

variable "api_max_count" {
  type = number
}

variable "db_instance_class" {
  type = string
}

variable "protect_data" {
  description = "Deletion protection on the DB/ALB and keep buckets on destroy"
  type        = bool
}

variable "certificate_arn" {
  type    = string
  default = null
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "retrain_schedule" {
  type    = string
  default = null
}

variable "drift_schedule" {
  type    = string
  default = null
}

variable "log_retention_days" {
  type    = number
  default = 30
}
