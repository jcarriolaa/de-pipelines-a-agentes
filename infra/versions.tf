terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # State local a propósito: el addon vive dos días y se destruye solo.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = "demo-addon"
      purpose    = "aws-community-day-gt-2026"
      managed_by = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # El addon apunta al pipeline solo por nombre: no lee su state, así que
  # valida y planea aunque la infra del pipeline esté abajo.
  pipeline_prefix      = "${var.pipeline_project}-${var.pipeline_env}"
  state_machine_arn    = "arn:${local.partition}:states:${var.region}:${local.account_id}:stateMachine:${local.pipeline_prefix}-pipeline"
  execution_arn_prefix = "arn:${local.partition}:states:${var.region}:${local.account_id}:execution:${local.pipeline_prefix}-pipeline"
  pipeline_log_group   = "/aws/lambda/${local.pipeline_prefix}-pipeline"
  meta_bucket          = "${local.pipeline_prefix}-meta"
  quarantine_bucket    = "${local.pipeline_prefix}-quarantine"

  image_uri = "${aws_ecr_repository.agent.repository_url}:${var.image_tag}"

  # Lo que el agente necesita saber del entorno; igual en AgentCore y Fargate.
  agent_env = {
    MODEL_PROVIDER           = var.model_provider
    MODEL_ID                 = var.model_provider == "bedrock" ? var.model_id : var.anthropic_model_id
    ANTHROPIC_KEY_SECRET_ARN = aws_secretsmanager_secret.anthropic_api_key.arn
    DIAGNOSIS_TOPIC_ARN      = aws_sns_topic.diagnosis.arn
    MAX_TURNS                = tostring(var.max_turns)
    MAX_BUDGET_USD           = tostring(var.max_budget_usd)
    META_BUCKET              = local.meta_bucket
    QUARANTINE_BUCKET        = local.quarantine_bucket
    PIPELINE_LOG_GROUP       = local.pipeline_log_group
    AWS_REGION               = var.region
    PR_ENABLED               = tostring(var.pr_enabled)
    GITHUB_REPO              = var.github_repo
    # ARN, no el valor: el runtime lo lee en el momento de abrir el PR.
    GITHUB_TOKEN_SECRET_ARN = aws_secretsmanager_secret.github_token.arn
  }
}
