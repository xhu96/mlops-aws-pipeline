variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "cluster_arn" {
  type = string
}

variable "namespace_id" {
  description = "Cloud Map private DNS namespace id"
  type        = string
}

variable "namespace_name" {
  type = string
}

variable "image" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "execution_role_name" {
  type = string
}

variable "models_bucket" {
  type = string
}

variable "models_bucket_arn" {
  type = string
}

variable "client_security_group_ids" {
  description = "Security groups allowed to call MLflow (the ML jobs)"
  type        = list(string)
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 30
}
