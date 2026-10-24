output "ecr_repositories" {
  value = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}

output "github_role_arns" {
  description = "Put these in the GitHub repo/environment variables AWS_CI_ROLE_ARN / AWS_DEPLOY_ROLE_ARN"
  value       = { for k, r in aws_iam_role.github : k => r.arn }
}
