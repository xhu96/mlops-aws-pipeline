# Batch ML jobs on ECS Fargate, started on a schedule by EventBridge Scheduler
# or on demand by GitHub Actions (`aws ecs run-task`):
#   retrain - train -> quality gate -> export bundle to S3   (GitHub retrain.yml)
#   drift   - PSI of captured traffic vs training profile    (daily)

locals {
  bundle_uri = var.bundle_uri
  common_env = [
    { name = "MLFLOW_TRACKING_URI", value = var.mlflow_tracking_uri },
    { name = "MLFLOW_DISABLE_TELEMETRY", value = "true" },
    { name = "BUNDLE_URI", value = local.bundle_uri },
    { name = "MODEL_DIR", value = "/tmp/model" },
    { name = "CAPTURE_BUCKET", value = var.capture_bucket },
  ]
  all_jobs = {
    retrain = { command = ["retrain"], entrypoint = null, schedule = var.retrain_schedule }
    drift = {
      command    = ["-m", "churn.monitoring.drift_job"]
      entrypoint = ["python"]
      schedule   = var.drift_schedule
    }
  }
  jobs = { for k, v in local.all_jobs : k => v if k != "retrain" || var.enable_training }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}/jobs"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-jobs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "Bundles"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.models_bucket_arn}/bundles/*", "${var.models_bucket_arn}/mlflow/*"]
  }
  statement {
    sid       = "ReadCapture"
    actions   = ["s3:GetObject"]
    resources = ["${var.capture_bucket_arn}/capture/*"]
  }
  statement {
    sid       = "List"
    actions   = ["s3:ListBucket"]
    resources = [var.models_bucket_arn, var.capture_bucket_arn]
  }
  statement {
    sid       = "DriftMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ChurnModel"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "ml-jobs"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

resource "aws_ecs_task_definition" "this" {
  for_each                 = local.jobs
  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([merge(
    {
      name        = each.key
      image       = var.image
      essential   = true
      command     = each.value.command
      environment = local.common_env
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.region
          awslogs-stream-prefix = each.key
        }
      }
    },
    each.value.entrypoint == null ? {} : { entryPoint = each.value.entrypoint }
  )])
}

# --- Schedules ----------------------------------------------------------------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-jobs-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["ecs:RunTask"]
    resources = [for td in aws_ecs_task_definition.this : td.arn_without_revision]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [var.execution_role_arn, aws_iam_role.task.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "run-jobs"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule" "this" {
  for_each                     = { for k, v in local.jobs : k => v if v.schedule != null }
  name                         = "${var.name}-${each.key}"
  schedule_expression          = each.value.schedule
  schedule_expression_timezone = "Europe/London"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.this[each.key].arn_without_revision
      launch_type         = "FARGATE"
      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = [var.security_group_id]
        assign_public_ip = true
      }
    }

    retry_policy {
      maximum_retry_attempts = 1
    }
  }
}
