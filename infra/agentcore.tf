# Runtime principal: Bedrock AgentCore Runtime. Una microVM por sesión, sin
# servidores que administrar; el contenedor expone POST /invocations y GET /ping
# (BedrockAgentCoreApp en main.py con AGENT_MODE=agentcore).
#
# Requiere la imagen publicada ANTES de crearse: `make push` y luego `make apply`.
resource "aws_bedrockagentcore_agent_runtime" "agent" {
  count = var.agentcore_enabled ? 1 : 0

  agent_runtime_name = replace(var.name, "-", "_")
  description        = "Agente de monitoreo del pipeline evtpipe: diagnostica ejecuciones FAILED."
  role_arn           = aws_iam_role.agentcore.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = local.image_uri
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "HTTP"
  }

  environment_variables = merge(local.agent_env, { AGENT_MODE = "agentcore" })

  depends_on = [
    aws_iam_role_policy.agentcore_runtime,
    aws_iam_role_policy_attachment.agentcore_readonly,
  ]
}
