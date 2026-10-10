# Demo "De pipelines a agentes": agente de monitoreo para evtpipe-dev (AWS Community Day GT 2026).
# Paso a paso completo: docs/GUIA-PASO-A-PASO.md

AWS_PROFILE ?= personal
AWS_REGION  ?= us-east-1
TAG         ?= $(shell date +%Y%m%d-%H%M%S)
TERRAFORM   ?= $(shell command -v terraform || echo $(HOME)/.local/bin/terraform)
TF          := $(TERRAFORM) -chdir=infra
# El estado del flujo programado se recuerda en infra/.flujo para que `make apply` no lo apague.
TF_VARS      = -var="image_tag=$$(cat infra/.image_tag)" -var="flujo_programado=$$(cat infra/.flujo 2>/dev/null || echo false)"
export AWS_PROFILE AWS_REGION

.PHONY: help login check-bedrock build dry-run smoke-agentcore-local infra-init infra-ecr push apply \
        runtime-fargate runtime-agentcore invoke-test validate happy reset break run watch destroy flujo-on flujo-off flujo-ahora

help: ## Esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

login: ## aws sso login con AWS_PROFILE (default: personal)
	aws sso login --profile $(AWS_PROFILE)

check-bedrock: ## ¿El modelo está habilitado en Bedrock? (requiere AWS CLI v2 reciente)
	aws bedrock list-inference-profiles --region $(AWS_REGION) \
		--query "inferenceProfileSummaries[?contains(inferenceProfileId, 'claude-sonnet')].[inferenceProfileId,status]" --output table

build: ## Imagen del agente (arm64: la exige AgentCore; Fargate corre la misma)
	docker build --platform linux/arm64 -t demo-agent:local agent

dry-run: build ## Valida imagen + runbook + binarios sin modelo ni AWS
	./demo/run_local.sh --dry-run

smoke-agentcore-local: build ## Levanta el contrato HTTP de AgentCore en local y le pega a /ping y /invocations (dry_run)
	@docker rm -f demo-agent-ac >/dev/null 2>&1 || true
	docker run -d --name demo-agent-ac --platform linux/arm64 -p 8080:8080 -e AGENT_MODE=agentcore demo-agent:local
	@sleep 4
	curl -sf localhost:8080/ping; echo
	curl -sf -X POST localhost:8080/invocations -H 'Content-Type: application/json' \
		-d "{\"dry_run\": true, \"event\": $$(cat demo/sample_event.json)}"; echo
	@docker rm -f demo-agent-ac >/dev/null

validate: ## terraform fmt + validate (sin AWS)
	$(TERRAFORM) -chdir=infra fmt -check -recursive
	$(TF) init -backend=false -input=false >/dev/null
	$(TF) validate

infra-init:
	$(TF) init -input=false

infra-ecr: infra-init ## Solo el repo ECR (la imagen debe existir antes de crear el runtime)
	$(TF) apply -target=aws_ecr_repository.agent -auto-approve

push: build ## Sube la imagen a ECR con tag fecha-hora y lo guarda en infra/.image_tag
	$(eval REPO := $(shell $(TF) output -raw ecr_repository_url))
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(firstword $(subst /, ,$(REPO)))
	docker tag demo-agent:local $(REPO):$(TAG)
	docker push $(REPO):$(TAG)
	@echo $(TAG) > infra/.image_tag
	@echo "IMAGE=$(REPO):$(TAG)"

apply: infra-init ## Todo el addon (AgentCore + respaldo Fargate + EventBridge + SNS)
	$(TF) apply $(TF_VARS)

runtime-fargate: ## PLAN B en AWS: el dispatcher pasa a Fargate (mismo agente)
	$(TF) apply $(TF_VARS) -var="agent_runtime=fargate"

runtime-agentcore: ## Volver a AgentCore
	$(TF) apply $(TF_VARS) -var="agent_runtime=agentcore"

invoke-test: ## Invoca el dispatcher con el evento de ejemplo (prueba del cableado, sin romper el pipeline)
	aws lambda invoke --function-name $$($(TF) output -raw dispatcher_function_name) \
		--invocation-type Event --cli-binary-format raw-in-base64-out \
		--payload file://demo/sample_event.json /dev/stdout

happy: ## Camino feliz en AWS: datos válidos + corrida completa (ANTES de romper nada)
	./demo/happy_path.sh --run

reset: ## Quita de bronze los archivos rotos pendientes (acción del operador, pide confirmación)
	./demo/reset_bronze.sh

break: ## Rompe el contrato (sube el archivo con customerId a bronze)
	./demo/break_contract.sh

run: ## Corre el pipeline y sigue su estado
	./demo/run_pipeline.sh

watch: ## Logs del agente en vivo
	./demo/watch_agent.sh

destroy: ## Destruye la infra del agente (no toca el pipeline)
	$(TF) destroy $(TF_VARS)

flujo-on: ## Enciende el productor del CRM: datos válidos + pipeline cada 10 min
	@echo true > infra/.flujo
	$(TF) apply $(TF_VARS)

flujo-off: ## Apaga el productor del CRM
	@echo false > infra/.flujo
	$(TF) apply $(TF_VARS)

flujo-ahora: ## Dispara el productor una vez, sin esperar al schedule
	aws lambda invoke --function-name demo-agent-productor-crm --cli-binary-format raw-in-base64-out /dev/stdout
