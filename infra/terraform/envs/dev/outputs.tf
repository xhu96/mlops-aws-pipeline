output "api_url" {
  value = module.stack.api_url
}

output "cluster_name" {
  value = module.stack.cluster_name
}

output "subnet_ids" {
  value = module.stack.subnet_ids
}

output "jobs_security_group_id" {
  value = module.stack.jobs_security_group_id
}

output "job_task_families" {
  value = module.stack.job_task_families
}

output "bundle_uri" {
  value = module.stack.bundle_uri
}

output "dashboard_url" {
  value = module.stack.dashboard_url
}

output "models_bucket" {
  value = module.stack.models_bucket
}
