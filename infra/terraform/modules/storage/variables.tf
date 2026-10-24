variable "name" {
  type = string
}

variable "account_id" {
  type = string
}

variable "capture_retention_days" {
  type    = number
  default = 30
}

variable "force_destroy" {
  description = "Allow terraform destroy to delete non-empty buckets (dev only)"
  type        = bool
  default     = false
}
