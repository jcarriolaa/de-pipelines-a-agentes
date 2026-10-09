data "archive_file" "dispatcher" {
  type        = "zip"
  source_file = "${path.module}/dispatcher/handler.py"
  output_path = "${path.module}/.build/dispatcher.zip"
}

resource "aws_cloudwatch_log_group" "dispatcher" {
  name              = "/aws/lambda/${var.name}-dispatcher"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "dispatcher" {
  function_name    = "${var.name}-dispatcher"
  description      = "Evento FAILED -> agente (${var.agent_runtime})."
  role             = aws_iam_role.dispatcher.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  filename         = data.archive_file.dispatcher.output_path
  source_code_hash = data.archive_file.dispatcher.output_base64sha256
  memory_size      = 256
  # AgentCore se invoca en síncrono y el diagnóstico tarda minutos: la Lambda
  # espera la respuesta (límite de AgentCore síncrono: 15 min).
  timeout = 900

  environment {
    variables = {
      AGENT_RUNTIME     = var.agent_runtime
      AGENT_RUNTIME_ARN = var.agentcore_enabled ? aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_arn : ""
      CLUSTER_ARN       = aws_ecs_cluster.agent.arn
      TASK_DEFINITION   = aws_ecs_task_definition.agent.arn
      SUBNETS           = join(",", data.aws_subnets.default.ids)
      SECURITY_GROUP    = aws_security_group.agent.id
    }
  }

  depends_on = [aws_cloudwatch_log_group.dispatcher, aws_iam_role_policy.dispatcher]
}

# Un evento = un diagnóstico. Si el dispatcher falla, NO se reintenta en
# automático (dos agentes sobre la misma falla confunden la demo).
resource "aws_lambda_function_event_invoke_config" "dispatcher" {
  function_name          = aws_lambda_function.dispatcher.function_name
  maximum_retry_attempts = 0
}
