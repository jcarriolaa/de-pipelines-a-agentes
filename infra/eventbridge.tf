# El disparador: el evento NATIVO de Step Functions cuando la ejecución del
# pipeline termina en FAILED. Inmediato (segundos), a diferencia de las alarmas
# de CloudWatch del pipeline, que tienen period de 1 hora.
resource "aws_cloudwatch_event_rule" "pipeline_failed" {
  name        = "${var.name}-pipeline-failed"
  description = "Una ejecución de ${local.pipeline_prefix}-pipeline terminó en FAILED: despertar al agente."

  event_pattern = jsonencode({
    source        = ["aws.states"]
    "detail-type" = ["Step Functions Execution Status Change"]
    detail = {
      status          = ["FAILED", "TIMED_OUT"]
      stateMachineArn = [local.state_machine_arn]
    }
  })
}

resource "aws_cloudwatch_event_target" "dispatcher" {
  rule      = aws_cloudwatch_event_rule.pipeline_failed.name
  target_id = "dispatcher"
  arn       = aws_lambda_function.dispatcher.arn

  retry_policy {
    maximum_event_age_in_seconds = 600
    maximum_retry_attempts       = 2
  }
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dispatcher.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.pipeline_failed.arn
}
