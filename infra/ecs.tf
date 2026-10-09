# Una imagen ARM64 sirve a los dos runtimes: AgentCore la exige ARM64 y Fargate
# la corre con runtime_platform ARM64.
resource "aws_ecr_repository" "agent" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Solo las 10 imágenes más recientes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

# --- Fargate (respaldo): existe siempre, cuesta $0 mientras no corre ----------
resource "aws_ecs_cluster" "agent" {
  name = var.name
}

resource "aws_cloudwatch_log_group" "agent_fargate" {
  name              = "/demo-addon/agent"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "agent" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  task_role_arn            = aws_iam_role.task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([{
    name      = "agent"
    image     = local.image_uri
    essential = true
    # EVENT_JSON lo inyecta el dispatcher como container override.
    environment = [for k, v in local.agent_env : { name = k, value = v }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.agent_fargate.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "agent"
      }
    }
  }])
}

# Red: VPC por defecto con IP pública. El agente solo necesita salir a las APIs
# de AWS (Bedrock, Step Functions, Logs, S3, SNS) y a ECR; no recibe tráfico.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "agent" {
  name        = "${var.name}-egress-only"
  description = "Agente de monitoreo: sin entrada, salida HTTPS."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "APIs de AWS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
