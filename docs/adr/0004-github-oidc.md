# ADR 0004: GitHub OIDC instead of access keys

**Status:** accepted

## Context
Storing an IAM user's access keys as GitHub secrets creates long-lived credentials that can leak through logs, forks or a compromised action, and must be rotated by hand.

## Decision
GitHub Actions authenticates with OpenID Connect. AWS trusts tokens from `token.actions.githubusercontent.com` for this repository only, and each role restricts the `sub` claim:

- `churn-github-ci`: `repo:xhu96/mlops-aws-pipeline:*`, push images and run read-only plans
- `churn-github-deploy-<env>`: `repo:xhu96/mlops-aws-pipeline:environment:<env>`, apply Terraform and run ML jobs

## Consequences
- No AWS secrets stored in GitHub at all; credentials last one hour.
- Prod credentials can only be obtained by a job in the `prod` environment, which requires a reviewer's approval.
- The deploy policy is scoped by service and by `churn-*` resource names rather than written resource by resource. A permission boundary is the next tightening step.
