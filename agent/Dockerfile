# Una sola imagen para los dos runtimes:
#   AgentCore Runtime -> AGENT_MODE=agentcore (servidor HTTP en :8080)
#   Fargate / local   -> EVENT_JSON=<evento> (corre una vez y termina)
# AgentCore exige linux/arm64; Fargate corre la misma imagen con runtime ARM64.
#   docker build --platform linux/arm64 -t demo-agent .
FROM python:3.13-slim

ARG AWSCLI_VERSION=2.31.0
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates ripgrep git \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m)-${AWSCLI_VERSION}.zip" -o /tmp/awscli.zip \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip \
 && apt-get purge -y unzip \
 && rm -rf /var/lib/apt/lists/*

# Usuario sin privilegios: el agente no necesita root para leer AWS.
RUN useradd --create-home --uid 1000 agent
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py runbook.md ./

USER agent
ENV HOME=/home/agent \
    PYTHONUNBUFFERED=1 \
    AWS_REGION=us-east-1 \
    AWS_DEFAULT_REGION=us-east-1 \
    AWS_PAGER=""
EXPOSE 8080
CMD ["python", "main.py"]
