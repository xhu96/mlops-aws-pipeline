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

variable "cluster_name" {
  type = string
}

variable "image" {
  type = string
}

variable "execution_role_arn" {
  type = string
}

variable "capture_bucket" {
  type = string
}

variable "capture_bucket_arn" {
  type = string
}

variable "models_bucket_arn" {
  type = string
}

variable "bundle_uri" {
  type = string
}

variable "model_version" {
  description = "Pinned bundle version: each ECS task definition revision = one code + one model version"
  type        = string
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "min_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 3
}

variable "allowed_cidrs" {
  description = "Who may call the API"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "certificate_arn" {
  description = "ACM certificate for HTTPS; null serves plain HTTP (dev only)"
  type        = string
  default     = null
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "log_retention_days" {
  type    = number
  default = 30
}
