output "ecr_repository_url" {
  description = "Destino de `make push`."
  value       = aws_ecr_repository.agent.repository_url
}

output "agent_runtime" {
  description = "Runtime activo del dispatcher."
  value       = var.agent_runtime
}

output "agentcore_runtime_arn" {
  description = "ARN del AgentCore Runtime (vacío si agentcore_enabled=false)."
  value       = var.agentcore_enabled ? aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_arn : ""
}

output "agentcore_runtime_id" {
  description = "ID del runtime; su log group es /aws/bedrock-agentcore/runtimes/<id>-DEFAULT."
  value       = var.agentcore_enabled ? aws_bedrockagentcore_agent_runtime.agent[0].agent_runtime_id : ""
}

output "diagnosis_topic_arn" {
  description = "Topic SNS del diagnóstico."
  value       = aws_sns_topic.diagnosis.arn
}

output "dispatcher_function_name" {
  description = "Lambda que recibe el evento FAILED."
  value       = aws_lambda_function.dispatcher.function_name
}

output "event_rule_name" {
  description = "Regla de EventBridge (su métrica TriggeredRules confirma el disparo)."
  value       = aws_cloudwatch_event_rule.pipeline_failed.name
}

output "fargate_log_group" {
  description = "Logs del agente cuando corre en Fargate."
  value       = aws_cloudwatch_log_group.agent_fargate.name
}

output "state_machine_arn" {
  description = "State machine vigilado."
  value       = local.state_machine_arn
}
