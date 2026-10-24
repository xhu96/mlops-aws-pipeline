variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "image" {
  description = "Trainer image"
  type        = string
}

variable "execution_role_arn" {
  type = string
}

variable "enable_training" {
  type = bool
}

variable "mlflow_tracking_uri" {
  description = "Empty when training is disabled"
  type        = string
}

variable "bundle_uri" {
  type = string
}

variable "models_bucket" {
  type = string
}

variable "models_bucket_arn" {
  type = string
}

variable "capture_bucket" {
  type = string
}

variable "capture_bucket_arn" {
  type = string
}

variable "retrain_schedule" {
  description = "EventBridge Scheduler expression, or null to disable"
  type        = string
  default     = null
}

variable "drift_schedule" {
  type    = string
  default = "cron(0 6 * * ? *)"
}

variable "log_retention_days" {
  type    = number
  default = 30
}
