output "api_url" {
  value = module.api.url
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "subnet_ids" {
  value = module.network.public_subnet_ids
}

output "jobs_security_group_id" {
  value = aws_security_group.jobs.id
}

output "job_task_families" {
  value = module.jobs.task_families
}

output "bundle_uri" {
  value = local.bundle_uri
}

output "models_bucket" {
  value = module.storage.models_bucket
}

output "dashboard_url" {
  value = module.monitoring.dashboard_url
}
