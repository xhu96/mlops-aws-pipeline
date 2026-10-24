variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "ecr_registry" {
  type = string
}

# Image tags are the git SHA of the commit being deployed, set by CI.
variable "api_image_tag" {
  type = string
}

variable "trainer_image_tag" {
  type = string
}

variable "mlflow_image_tag" {
  type = string
}

variable "model_version" {
  description = "Bundle version to serve; CI reads it from bundles/champion.json"
  type        = string
}

variable "alert_emails" {
  type    = list(string)
  default = []
}

variable "certificate_arn" {
  type    = string
  default = null
}
