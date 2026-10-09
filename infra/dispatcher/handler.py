"""Dispatcher: evento FAILED de Step Functions -> agente de monitoreo.

Solo arma el payload y lanza el agente en el runtime configurado. Cambiar de
AgentCore a Fargate es cambiar AGENT_RUNTIME; el agente es el mismo.
"""

import json
import os
import uuid

import boto3
from botocore.config import Config

RUNTIME = os.environ["AGENT_RUNTIME"]

# El diagnóstico tarda minutos: sin esto boto3 corta a los 60 s y REINTENTA,
# y cada reintento arranca otro agente sobre la misma falla.
AGENTCORE = boto3.client(
    "bedrock-agentcore",
    config=Config(read_timeout=880, connect_timeout=10, retries={"total_max_attempts": 1}),
)


def handler(event, context):
    execution_arn = event.get("detail", {}).get("executionArn", "?")
    print(json.dumps({"dispatch": RUNTIME, "execution_arn": execution_arn}))

    if RUNTIME == "agentcore":
        response = AGENTCORE.invoke_agent_runtime(
            agentRuntimeArn=os.environ["AGENT_RUNTIME_ARN"],
            runtimeSessionId=f"diag-{uuid.uuid4()}",  # AgentCore pide >= 33 caracteres
            payload=json.dumps({"event": event}).encode("utf-8"),
        )
        body = response["response"].read().decode("utf-8")
        print(json.dumps({"agentcore_response": body[:4000]}))
        return {"runtime": RUNTIME, "status": response.get("statusCode")}

    # Fargate (respaldo): contenedor efímero, el evento viaja como env var.
    response = boto3.client("ecs").run_task(
        cluster=os.environ["CLUSTER_ARN"],
        taskDefinition=os.environ["TASK_DEFINITION"],
        launchType="FARGATE",
        count=1,
        networkConfiguration={
            "awsvpcConfiguration": {
                "subnets": os.environ["SUBNETS"].split(","),
                "securityGroups": [os.environ["SECURITY_GROUP"]],
                "assignPublicIp": "ENABLED",
            }
        },
        overrides={
            "containerOverrides": [
                {"name": "agent", "environment": [{"name": "EVENT_JSON", "value": json.dumps(event)}]}
            ]
        },
    )
    task_arns = [t["taskArn"] for t in response.get("tasks", [])]
    print(json.dumps({"task_arns": task_arns, "failures": response.get("failures", [])}))
    if not task_arns:
        raise RuntimeError(f"RunTask no arrancó la task: {response.get('failures')}")
    return {"runtime": RUNTIME, "task_arns": task_arns}
