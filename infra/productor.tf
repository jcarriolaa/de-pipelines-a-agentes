# Productor del CRM para que el pipeline se vea vivo: cada N minutos sube eventos
# VÁLIDOS a bronze y arranca una ejecución. Se pausa solo si hay un archivo roto
# pendiente (después de `make break`) o si el pipeline ya está corriendo.
# Apagado por defecto: `make flujo-on` / `make flujo-off`.
#
# No es el agente: es la "fuente de datos" de la demo. Por eso SÍ escribe en
# bronze y arranca el pipeline; el rol del agente sigue sin poder hacer nada de eso.

data "archive_file" "productor" {
  type        = "zip"
  source_file = "${path.module}/productor/handler.py"
  output_path = "${path.module}/.build/productor.zip"
}

resource "aws_cloudwatch_log_group" "productor" {
  name              = "/aws/lambda/${var.name}-productor-crm"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "productor" {
  statement {
    sid       = "OwnLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.productor.arn}:*"]
  }

  statement {
    sid       = "ListBronze"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${local.pipeline_prefix}-bronze"]
  }

  statement {
    sid       = "WriteCrmEvents"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:${local.partition}:s3:::${local.pipeline_prefix}-bronze/source=crm/*"]
  }

  # Bronze cifra con la key del pipeline (SSE-KMS): escribir necesita la key.
  statement {
    sid       = "EncryptWithPipelineKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Encrypt"]
    resources = ["*"]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:ResourceAliases"
      values   = ["alias/${local.pipeline_prefix}"]
    }
  }

  statement {
    sid       = "RunPipeline"
    effect    = "Allow"
    actions   = ["states:StartExecution", "states:ListExecutions"]
    resources = [local.state_machine_arn]
  }
}

resource "aws_iam_role" "productor" {
  name               = "${var.name}-productor-crm"
  description        = "Productor de datos de la demo: sube eventos válidos a bronze y corre el pipeline."
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "productor" {
  name   = "productor"
  role   = aws_iam_role.productor.id
  policy = data.aws_iam_policy_document.productor.json
}

resource "aws_lambda_function" "productor" {
  function_name    = "${var.name}-productor-crm"
  description      = "Cada ${var.flujo_cada_minutos} min: eventos válidos del CRM a bronze + ejecución del pipeline."
  role             = aws_iam_role.productor.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.productor.output_path
  source_code_hash = data.archive_file.productor.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      BRONZE_BUCKET     = "${local.pipeline_prefix}-bronze"
      STATE_MACHINE_ARN = local.state_machine_arn
      RECORDS           = "60"
    }
  }

  depends_on = [aws_cloudwatch_log_group.productor, aws_iam_role_policy.productor]
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "productor_scheduler" {
  name               = "${var.name}-productor-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "productor_scheduler" {
  name = "invoke"
  role = aws_iam_role.productor_scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.productor.arn }]
  })
}

resource "aws_scheduler_schedule" "productor" {
  name        = "${var.name}-productor-crm"
  description = "El CRM manda datos cada ${var.flujo_cada_minutos} min (demo)."
  state       = var.flujo_programado ? "ENABLED" : "DISABLED"

  schedule_expression = "rate(${var.flujo_cada_minutos} minutes)"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.productor.arn
    role_arn = aws_iam_role.productor_scheduler.arn

    retry_policy {
      maximum_retry_attempts = 0
    }
  }
}
