variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the CI roles"
  type        = string
  default     = "xhu96/mlops-aws-pipeline"
}

variable "environments" {
  description = "GitHub environments that get their own deploy role"
  type        = list(string)
  default     = ["dev", "prod"]
}
