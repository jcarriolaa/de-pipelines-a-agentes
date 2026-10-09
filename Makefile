# Demo "De pipelines a agentes": agente de monitoreo para evtpipe-dev (AWS Community Day GT 2026).
# Orden del viernes: login -> check-bedrock -> infra-ecr -> push -> apply -> confirmar email -> e2e.

AWS_PROFILE ?= personal
AWS_REGION  ?= us-east-1
TAG         ?= $(shell date +%Y%m%d-%H%M%S)
TERRAFORM   ?= $(shell command -v terraform || echo $(HOME)/.local/bin/terraform)
TF          := $(TERRAFORM) -chdir=infra
export AWS_PROFILE AWS_REGION

.PHONY: help login check-bedrock build dry-run smoke-agentcore-local infra-init infra-ecr push apply \
        runtime-fargate runtime-agentcore invoke-test validate happy reset break run watch destroy

help: ## Esta ayuda
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'

login: ## SSO del perfil personal
	aws sso login --profile $(AWS_PROFILE)

check-bedrock: ## PASO 1 DEL VIERNES: ¿el inference profile de Sonnet existe en la cuenta?
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
	$(TF) apply -var="image_tag=$$(cat infra/.image_tag)"

runtime-fargate: ## PLAN B en AWS: el dispatcher pasa a Fargate (mismo agente)
	$(TF) apply -var="image_tag=$$(cat infra/.image_tag)" -var="agent_runtime=fargate"

runtime-agentcore: ## Volver a AgentCore
	$(TF) apply -var="image_tag=$$(cat infra/.image_tag)" -var="agent_runtime=agentcore"

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

destroy: ## Destruye SOLO el addon (después del sábado)
	$(TF) destroy -var="image_tag=$$(cat infra/.image_tag)"
