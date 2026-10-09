# Token de GitHub para el draft PR. Terraform crea el secreto VACÍO: el valor
# lo pone una persona a mano (fine-grained PAT, solo este repo, Contents + Pull
# requests en read/write). Lo lee el RUNTIME, no el modelo: nunca entra al
# contexto del agente ni a los logs.
resource "aws_secretsmanager_secret" "github_token" {
  name                    = "${var.name}/github-token"
  description             = "PAT fine-grained para que el runtime del agente abra draft PRs en ${var.github_repo}."
  recovery_window_in_days = 0
}

# Plan B1: API key de Anthropic, por si Bedrock no habilita el modelo en la
# cuenta. Mismo patrón: el secreto nace vacío y el valor lo pone una persona.
resource "aws_secretsmanager_secret" "anthropic_api_key" {
  name                    = "${var.name}/anthropic-api-key"
  description             = "API key de Anthropic para el agente cuando model_provider = anthropic."
  recovery_window_in_days = 0
}
