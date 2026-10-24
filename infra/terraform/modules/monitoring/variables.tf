variable "name" {
  type = string
}

variable "region" {
  type = string
}

variable "github_repository" {
  type = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "alb_arn_suffix" {
  type = string
}

variable "target_group_arn_suffix" {
  type = string
}

variable "cluster_arn" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "api_service_name" {
  type = string
}

variable "api_log_group" {
  type = string
}

variable "job_task_families" {
  type = list(string)
}

variable "latency_p95_ms" {
  type    = number
  default = 500
}

variable "psi_threshold" {
  type    = number
  default = 0.2
}
