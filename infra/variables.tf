variable "region" {
  description = "Región de la demo; la misma del pipeline."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Prefijo de todos los recursos del addon."
  type        = string
  default     = "demo-agent"
}

variable "pipeline_project" {
  description = "Proyecto del pipeline existente (prefijo de sus recursos)."
  type        = string
  default     = "evtpipe"
}

variable "pipeline_env" {
  description = "Entorno del pipeline que vigila el agente."
  type        = string
  default     = "dev"
}

variable "agent_runtime" {
  description = "Dónde corre el agente: agentcore (principal) o fargate (respaldo). Cambiarlo solo re-configura el dispatcher."
  type        = string
  default     = "agentcore"

  validation {
    condition     = contains(["agentcore", "fargate"], var.agent_runtime)
    error_message = "agent_runtime debe ser agentcore o fargate."
  }
}

variable "agentcore_enabled" {
  description = "Crea el AgentCore Runtime. Necesita la imagen ya publicada en ECR (make push antes del apply completo)."
  type        = bool
  default     = true
}

variable "image_tag" {
  description = "Tag de la imagen del agente en ECR."
  type        = string
  default     = "latest"
}

variable "model_id" {
  description = "Inference profile de Bedrock, con ID completo (nunca alias). Verificar con: aws bedrock list-inference-profiles."
  type        = string
  default     = "us.anthropic.claude-sonnet-4-6"
}

variable "max_turns" {
  description = "Tope de turnos del agente."
  type        = number
  default     = 40
}

variable "max_budget_usd" {
  description = "Tope de gasto por diagnóstico."
  type        = number
  default     = 1.0
}

variable "notification_email" {
  description = "Destino del diagnóstico (va en terraform.tfvars, que no se versiona). Llega un correo de confirmación: hay que aceptarlo."
  type        = string
}

variable "log_retention_days" {
  description = "Retención de los logs del addon."
  type        = number
  default     = 7
}

variable "pr_enabled" {
  description = "El agente propone el arreglo como draft PR. Requiere el token en el secreto demo-agent/github-token."
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "Repo donde el agente abre el draft PR (owner/nombre)."
  type        = string
  default     = "jcarriolaa/de-pipelines-a-agentes"
}

variable "model_provider" {
  description = "Dónde corre el modelo: bedrock (plan A) o anthropic (plan B1: API de Anthropic, mismo AgentCore). Cambiarlo no toca el agente."
  type        = string
  default     = "bedrock"

  validation {
    condition     = contains(["bedrock", "anthropic"], var.model_provider)
    error_message = "model_provider debe ser bedrock o anthropic."
  }
}

variable "anthropic_model_id" {
  description = "Modelo cuando model_provider = anthropic (mismo Sonnet 4.6)."
  type        = string
  default     = "claude-sonnet-4-6"
}
