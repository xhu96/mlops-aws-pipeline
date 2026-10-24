# MLflow tracking server + model registry.
# Private by design: no load balancer, reachable only from the ML job tasks via
# Cloud Map DNS (mlflow.<namespace>:5000). Humans use `aws ecs execute-command`
# port forwarding (see docs/runbook.md). Metadata in RDS PostgreSQL, artifacts in S3.

resource "aws_security_group" "mlflow" {
  name        = "${var.name}-mlflow"
  description = "MLflow server: port 5000 from ML jobs only"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_vpc_security_group_ingress_rule" "mlflow_from_clients" {
  count                        = length(var.client_security_group_ids)
  security_group_id            = aws_security_group.mlflow.id
  referenced_security_group_id = var.client_security_group_ids[count.index]
  from_port                    = 5000
  to_port                      = 5000
  ip_protocol                  = "tcp"
}

resource "aws_security_group" "db" {
  name        = "${var.name}-mlflow-db"
  description = "MLflow metadata DB: Postgres from MLflow server only"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.mlflow.id]
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-mlflow"
  subnet_ids = var.subnet_ids
}

resource "aws_db_instance" "this" {
  identifier                  = "${var.name}-mlflow"
  engine                      = "postgres"
  engine_version              = "17"
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "mlflow"
  username                    = "mlflow"
  manage_master_user_password = true # password generated and rotated in Secrets Manager
  db_subnet_group_name        = aws_db_subnet_group.this.name
  vpc_security_group_ids      = [aws_security_group.db.id]
  publicly_accessible         = false
  backup_retention_period     = var.backup_retention_days
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = !var.deletion_protection
  final_snapshot_identifier   = var.deletion_protection ? "${var.name}-mlflow-final" : null
  auto_minor_version_upgrade  = true
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}/mlflow"
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
  name               = "${var.name}-mlflow-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

data "aws_iam_policy_document" "task" {
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.models_bucket_arn}/mlflow/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [var.models_bucket_arn]
  }
  statement {
    # ECS Exec, for the port-forwarding path to the UI
    actions = [
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "mlflow"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

data "aws_iam_policy_document" "read_db_secret" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_db_instance.this.master_user_secret[0].secret_arn]
  }
}

resource "aws_iam_role_policy" "execution_db_secret" {
  name   = "${var.name}-mlflow-db-secret"
  role   = var.execution_role_name
  policy = data.aws_iam_policy_document.read_db_secret.json
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-mlflow"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "mlflow"
    image     = var.image
    essential = true
    command = [
      "--artifacts-destination", "s3://${var.models_bucket}/mlflow",
      "--allowed-hosts", "mlflow.${var.namespace_name}:5000,localhost:5000",
    ]
    portMappings = [{ containerPort = 5000, protocol = "tcp" }]
    environment = [
      { name = "DB_HOST", value = aws_db_instance.this.address },
      { name = "DB_USER", value = aws_db_instance.this.username },
      { name = "DB_NAME", value = aws_db_instance.this.db_name },
      { name = "MLFLOW_DISABLE_TELEMETRY", value = "true" },
    ]
    secrets = [{
      name      = "DB_PASSWORD"
      valueFrom = "${aws_db_instance.this.master_user_secret[0].secret_arn}:password::"
    }]
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/health')"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 30
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "mlflow"
      }
    }
  }])
}

resource "aws_service_discovery_service" "this" {
  name = "mlflow"
  dns_config {
    namespace_id = var.namespace_id
    dns_records {
      type = "A"
      ttl  = 10
    }
    routing_policy = "MULTIVALUE"
  }
}

resource "aws_ecs_service" "this" {
  name                   = "mlflow"
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.mlflow.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.this.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
}
