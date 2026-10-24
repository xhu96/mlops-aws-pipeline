# GitHub Actions authenticates to AWS with short-lived OIDC tokens: there are no
# long-lived access keys stored in GitHub. Each role trusts a specific subject:
#   ci            -> any ref or PR of the repo: build/push images, terraform plan
#   deploy-<env>  -> only jobs running in that GitHub environment (prod needs approval)

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  state_arn   = "arn:aws:s3:::churn-tfstate-${local.account_id}"
  oidc_claims = "token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
  for_each = merge(
    { ci = "repo:${var.github_repository}:*" },
    { for env in var.environments : "deploy-${env}" => "repo:${var.github_repository}:environment:${env}" }
  )

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_claims}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "${local.oidc_claims}:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "github" {
  for_each             = data.aws_iam_policy_document.trust
  name                 = "churn-github-${each.key}"
  assume_role_policy   = each.value.json
  max_session_duration = 3600
}

# --- CI: push images, read-only plan -----------------------------------------
data "aws_iam_policy_document" "ci" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:DescribeImageScanFindings", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.this : r.arn]
  }
  statement {
    sid       = "TerraformStateLock"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.state_arn}/*"]
  }
  statement {
    sid       = "TerraformStateList"
    actions   = ["s3:ListBucket"]
    resources = [local.state_arn]
  }
}

resource "aws_iam_role_policy" "ci" {
  name   = "ci"
  role   = aws_iam_role.github["ci"].id
  policy = data.aws_iam_policy_document.ci.json
}

resource "aws_iam_role_policy_attachment" "ci_readonly" {
  role       = aws_iam_role.github["ci"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# --- Deploy: terraform apply + run ML jobs, scoped to churn-* resources --------
data "aws_iam_policy_document" "deploy" {
  statement {
    sid = "ManagedServices"
    actions = [
      "ec2:*", "ecs:*", "elasticloadbalancing:*", "application-autoscaling:*", "rds:*",
      "logs:*", "cloudwatch:*", "sns:*", "scheduler:*", "servicediscovery:*", "route53:*",
      "secretsmanager:DescribeSecret", "secretsmanager:GetResourcePolicy", "kms:DescribeKey",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "ProjectBuckets"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::churn-*", "arn:aws:s3:::churn-*/*"]
  }
  statement {
    sid = "ProjectRoles"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole", "iam:TagRole",
      "iam:UntagRole", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:AttachRolePolicy",
      "iam:DetachRolePolicy", "iam:ListInstanceProfilesForRole", "iam:PassRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/churn-*"]
  }
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/aws-service-role/*"]
  }
  statement {
    sid       = "EcrRead"
    actions   = ["ecr:GetAuthorizationToken", "ecr:DescribeImages", "ecr:BatchGetImage"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = toset(var.environments)
  name     = "deploy"
  role     = aws_iam_role.github["deploy-${each.key}"].id
  policy   = data.aws_iam_policy_document.deploy.json
}

resource "aws_iam_role_policy" "deploy_state" {
  for_each = toset(var.environments)
  name     = "terraform-state"
  role     = aws_iam_role.github["deploy-${each.key}"].id
  policy   = data.aws_iam_policy_document.ci.json
}
