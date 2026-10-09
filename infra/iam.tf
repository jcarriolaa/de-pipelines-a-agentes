# Tres roles, cada uno con lo mínimo:
#   agente     (AgentCore o Fargate task role) -> LEE el pipeline + sns:Publish
#   ejecución  (Fargate)                       -> pull de ECR + escribir sus logs
#   dispatcher (Lambda)                        -> lanzar el agente, nada más
#
# Regla de la charla: el agente NO tiene ningún permiso de escritura sobre el
# pipeline. Lo único con efecto: sns:Publish a su topic y leer el token de
# GitHub (que usa el RUNTIME para un draft PR, nunca el modelo).

# --- lo que el agente puede hacer (igual en los dos runtimes) -----------------
data "aws_iam_policy_document" "agent_readonly" {
  statement {
    sid       = "ReadPipelineExecutions"
    effect    = "Allow"
    actions   = ["states:GetExecutionHistory", "states:DescribeExecution"]
    resources = ["${local.execution_arn_prefix}:*"]
  }

  statement {
    sid    = "ReadPipelineLogs"
    effect = "Allow"
    actions = [
      "logs:StartQuery",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.pipeline_prefix}-*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.pipeline_prefix}-*:*",
    ]
  }

  # GetQueryResults/StopQuery no aceptan ARN de log group: AWS documenta "*".
  statement {
    sid       = "ReadQueryResults"
    effect    = "Allow"
    actions   = ["logs:GetQueryResults"]
    resources = ["*"]
  }

  statement {
    sid     = "ReadManifestsAndQuarantine"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:${local.partition}:s3:::${local.meta_bucket}",
      "arn:${local.partition}:s3:::${local.meta_bucket}/*",
      "arn:${local.partition}:s3:::${local.quarantine_bucket}",
      "arn:${local.partition}:s3:::${local.quarantine_bucket}/*",
    ]
  }

  # Los buckets del pipeline usan SSE-KMS con la key del entorno: sin Decrypt no
  # se puede leer el manifest. Solo Decrypt, y solo sobre esa key (por alias).
  statement {
    sid       = "DecryptPipelineKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.pipeline_prefix}"]
    }
  }

  statement {
    sid       = "PublishDiagnosis"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.diagnosis.arn]
  }

  # Token de GitHub (draft PR) y API key de Anthropic (plan B1): los lee el
  # RUNTIME, nunca el modelo.
  statement {
    sid     = "ReadRuntimeSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      aws_secretsmanager_secret.github_token.arn,
      aws_secretsmanager_secret.anthropic_api_key.arn,
    ]
  }

  # Inference profiles cross-region (us.*) enrutan a modelos en varias regiones.
  statement {
    sid    = "InvokeClaudeOnBedrock"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/anthropic.*",
      "arn:${local.partition}:bedrock:*:${local.account_id}:inference-profile/*anthropic.*",
    ]
  }

  # Bedrock habilita los modelos de Anthropic vía AWS Marketplace y verifica
  # la suscripción CON EL ROL QUE INVOCA: sin esto, 403 "Model access is
  # denied ... aws-marketplace:ViewSubscriptions, aws-marketplace:Subscribe".
  # Es a nivel de cuenta sobre el modelo; no toca nada del pipeline.
  statement {
    sid       = "BedrockModelSubscription"
    effect    = "Allow"
    actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
    resources = ["*"]
  }

  statement {
    sid    = "DiscoverInferenceProfiles"
    effect = "Allow"
    actions = [
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
    ]
    resources = ["*"]
  }

  # Cinturón y tirantes: aunque nada de arriba lo permite, se niega explícito.
  # Un Deny gana sobre cualquier Allow que alguien agregue después por error.
  statement {
    sid    = "NeverChangeThePipeline"
    effect = "Deny"
    actions = [
      "states:StartExecution",
      "states:StopExecution",
      "states:RedriveExecution",
      "states:UpdateStateMachine",
      "lambda:InvokeFunction",
      "lambda:Update*",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "iam:*",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecret",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "agent_readonly" {
  name        = "${var.name}-readonly"
  description = "Agente de monitoreo: lee Step Functions, logs y S3 del pipeline; solo publica en su topic SNS."
  policy      = data.aws_iam_policy_document.agent_readonly.json
}

# --- AgentCore Runtime ---------------------------------------------------------
data "aws_iam_policy_document" "agentcore_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "agentcore" {
  name               = "${var.name}-agentcore"
  description        = "Identidad del agente en AgentCore Runtime."
  assume_role_policy = data.aws_iam_policy_document.agentcore_assume.json
}

# Plomería que AgentCore necesita para arrancar el contenedor y emitir
# observabilidad (logs, trazas, métricas). Escribe SOLO en sus propios logs.
data "aws_iam_policy_document" "agentcore_runtime" {
  statement {
    sid       = "PullAgentImage"
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.agent.arn]
  }

  statement {
    sid       = "EcrToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "OwnRuntimeLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
      "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*:log-stream:*",
    ]
  }

  statement {
    sid       = "DescribeLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid    = "Traces"
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RuntimeMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["bedrock-agentcore"]
    }
  }

  statement {
    sid    = "WorkloadIdentity"
    effect = "Allow"
    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
      "bedrock-agentcore:GetWorkloadAccessTokenForUserId",
    ]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default",
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:workload-identity-directory/default/workload-identity/*",
    ]
  }
}

resource "aws_iam_role_policy" "agentcore_runtime" {
  name   = "runtime"
  role   = aws_iam_role.agentcore.id
  policy = data.aws_iam_policy_document.agentcore_runtime.json
}

resource "aws_iam_role_policy_attachment" "agentcore_readonly" {
  role       = aws_iam_role.agentcore.name
  policy_arn = aws_iam_policy.agent_readonly.arn
}

# --- Fargate (respaldo) --------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

# Task role = la identidad del agente en Fargate. Solo la política read-only.
resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  description        = "Identidad del agente en Fargate (respaldo de AgentCore)."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_readonly" {
  role       = aws_iam_role.task.name
  policy_arn = aws_iam_policy.agent_readonly.arn
}

# Execution role = lo que ECS usa para arrancar el contenedor, no el agente.
resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  description        = "ECS: pull de la imagen del agente y envío de sus logs."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Dispatcher ----------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dispatcher" {
  name               = "${var.name}-dispatcher"
  description        = "Recibe el evento FAILED y lanza el agente."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "dispatcher" {
  statement {
    sid       = "OwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.dispatcher.arn}:*"]
  }

  statement {
    sid     = "InvokeAgentCore"
    effect  = "Allow"
    actions = ["bedrock-agentcore:InvokeAgentRuntime"]
    resources = [
      "arn:${local.partition}:bedrock-agentcore:${var.region}:${local.account_id}:runtime/*",
    ]
  }

  statement {
    sid       = "RunAgentTask"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = ["arn:${local.partition}:ecs:${var.region}:${local.account_id}:task-definition/${var.name}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.agent.arn]
    }
  }

  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task.arn, aws_iam_role.execution.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "dispatcher" {
  name   = "dispatch"
  role   = aws_iam_role.dispatcher.id
  policy = data.aws_iam_policy_document.dispatcher.json
}
