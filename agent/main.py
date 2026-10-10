"""Agente de monitoreo: un Step Functions FAILED entra; un diagnóstico y un draft PR salen.

Reparto de responsabilidades (es el guardrail principal):

  * El AGENTE (modelo) razona: diagnostica leyendo AWS en solo lectura y, si hay
    repo, edita contracts/, src/ y tests/ en un clon local. No tiene git, ni
    token, ni forma de publicar nada.
  * El RUNTIME (este archivo, código determinístico) actúa: saca el token de
    Secrets Manager (el modelo nunca lo ve), verifica que el diff solo toque
    rutas permitidas, hace commit [skip ci], push a agent/* y abre un DRAFT PR,
    y publica el diagnóstico en SNS con el link.

Runtimes (el agente es el mismo):

  * Fargate / local : ``python main.py`` lee el evento de EVENT_JSON (o --event).
  * AgentCore       : AGENT_MODE=agentcore levanta el contrato HTTP de AgentCore.

``--dry-run`` valida imagen, runbook y binarios sin modelo ni AWS.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    TextBlock,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
    query,
)

HERE = Path(__file__).resolve().parent

REGION = os.environ.get("AWS_REGION", "us-east-1")
# Dónde corre el modelo (el agente y los guardrails no cambian):
#   bedrock   : Claude en Amazon Bedrock (plan A)
#   anthropic : API de Anthropic con key en Secrets Manager (plan B1, mismo AgentCore)
#   local     : la sesión de Claude Code de la máquina (pruebas y plan B2)
MODEL_PROVIDER = os.environ.get("MODEL_PROVIDER", "bedrock")
ANTHROPIC_KEY_SECRET_ARN = os.environ.get("ANTHROPIC_KEY_SECRET_ARN", "")
# PIN con ID completo, nunca alias: el número de costo del deck depende del modelo.
MODEL_ID = os.environ.get(
    "MODEL_ID", "us.anthropic.claude-sonnet-4-6" if MODEL_PROVIDER == "bedrock" else "claude-sonnet-4-6"
)
TOPIC_ARN = os.environ.get("DIAGNOSIS_TOPIC_ARN", "")
MAX_TURNS = int(os.environ.get("MAX_TURNS", "40"))
MAX_BUDGET_USD = float(os.environ.get("MAX_BUDGET_USD", "1.00"))
META_BUCKET = os.environ.get("META_BUCKET", "evtpipe-dev-meta")
QUARANTINE_BUCKET = os.environ.get("QUARANTINE_BUCKET", "evtpipe-dev-quarantine")
PIPELINE_LOG_GROUP = os.environ.get("PIPELINE_LOG_GROUP", "/aws/lambda/evtpipe-dev-pipeline")

# --- PR ----------------------------------------------------------------------
PR_ENABLED = os.environ.get("PR_ENABLED", "false").lower() == "true"
GITHUB_REPO = os.environ.get("GITHUB_REPO", "jcarriolaa/de-pipelines-a-agentes")
# El repo de demo tiene un CI que solo corre pytest: se deja correr en el PR.
SKIP_CI = os.environ.get("SKIP_CI", "false").lower() == "true"
GITHUB_TOKEN_SECRET_ARN = os.environ.get("GITHUB_TOKEN_SECRET_ARN", "")
# Prueba local: copia este checkout en vez de clonar, y muestra el diff sin push.
REPO_SOURCE_DIR = os.environ.get("REPO_SOURCE_DIR", "")
PR_DRY_RUN = os.environ.get("PR_DRY_RUN", "false").lower() == "true"
WORK_DIR = Path(os.environ.get("WORK_DIR", "/tmp/work"))
# Lo único que el agente puede cambiar. El runtime lo vuelve a verificar sobre
# el diff real antes del commit: no basta con que el modelo "se porte bien".
EDITABLE_PREFIXES = ("contracts/", "src/", "tests/")

# Pre-aprobados. Con permission_mode="dontAsk" todo lo que NO esté aquí se
# deniega: esa combinación es el guardrail del lado del agente. El otro lado
# (el que no depende del modelo) es el rol IAM read-only.
AWS_READ_TOOLS = [
    "Bash(aws stepfunctions get-execution-history *)",
    "Bash(aws stepfunctions describe-execution *)",
    "Bash(aws logs start-query *)",
    "Bash(aws logs get-query-results *)",
    "Bash(aws logs filter-log-events *)",
    # Con y sin comillas: el modelo a veces cita la URI ("s3://...") y la regla
    # es un match literal de prefijo. Sigue limitado al bucket meta.
    f"Bash(aws s3 cp s3://{META_BUCKET}/*)",
    f'Bash(aws s3 cp "s3://{META_BUCKET}/*)',
    "Bash(aws s3 ls *)",
]
REPO_EDIT_TOOLS = [
    "Edit(contracts/**)",
    "Edit(src/**)",
    "Edit(tests/**)",
    "Write(tests/**)",
    "Bash(git diff*)",
    "Bash(git status*)",
    "Bash(python -m pytest*)",
    "Bash(PYTHONPATH=src python -m pytest*)",
]

DIAGNOSIS_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "causa": {"type": "string"},
        "evidencia": {"type": "array", "items": {"type": "string"}},
        "fix_propuesto": {"type": "string"},
        "requiere_humano": {"type": "boolean"},
        "run_id": {"type": "string"},
        "pr_titulo": {"type": "string"},
        "pr_descripcion": {"type": "string"},
    },
    "required": ["causa", "evidencia", "fix_propuesto", "requiere_humano", "run_id"],
    "additionalProperties": False,
}


# El repo no lleva atribuciones automáticas ("Generated with ...", Co-Authored-By):
# el runtime las borra en código antes de publicar, sin depender del modelo.
_ATTRIBUTION = re.compile(
    r"(generated with|co-authored-by|🤖)", re.IGNORECASE
)


def sin_atribucion(texto: str) -> str:
    lineas = [linea for linea in texto.splitlines() if not _ATTRIBUTION.search(linea)]
    return "\n".join(lineas).strip()


def limpiar(diagnosis: dict[str, Any]) -> dict[str, Any]:
    limpio = {k: sin_atribucion(v) if isinstance(v, str) else v for k, v in diagnosis.items()}
    if isinstance(limpio.get("evidencia"), list):
        limpio["evidencia"] = [sin_atribucion(e) for e in limpio["evidencia"] if sin_atribucion(e)]
    return limpio


def log(event: str, **fields: Any) -> None:
    """Una línea JSON por evento: CloudWatch Logs Insights la parsea sola."""
    print(json.dumps({"ts": time.time(), "event": event, **fields}, default=str), flush=True)


def load_runbook() -> str:
    return (HERE / "runbook.md").read_text(encoding="utf-8")


def git(repo: Path, *args: str, check: bool = True) -> str:
    out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        # Nunca loguear la URL con token: los errores de git pueden incluirla.
        raise RuntimeError(f"git {args[0]} falló: {out.stderr.strip()[:300]}")
    return out.stdout


def github_token() -> str:
    import boto3

    value = boto3.client("secretsmanager", region_name=REGION).get_secret_value(
        SecretId=GITHUB_TOKEN_SECRET_ARN
    )["SecretString"]
    return value.strip()


def prepare_repo(branch: str) -> Path | None:
    """Clon fresco del repo en una rama agent/*. None si el PR está apagado."""
    if not PR_ENABLED:
        return None
    repo = WORK_DIR / "repo"
    shutil.rmtree(repo, ignore_errors=True)
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    if REPO_SOURCE_DIR:
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", f"file://{REPO_SOURCE_DIR}", str(repo)], check=True)
    else:
        url = f"https://x-access-token:{github_token()}@github.com/{GITHUB_REPO}.git"
        subprocess.run(["git", "clone", "--quiet", "--depth", "1", url, str(repo)], check=True,
                       capture_output=True)
        # El token no se queda en .git/config: el agente puede leer archivos.
        git(repo, "remote", "set-url", "origin", f"https://github.com/{GITHUB_REPO}.git")
    git(repo, "checkout", "--quiet", "-b", branch)
    log("repo_ready", repo=GITHUB_REPO, branch=branch, source="local" if REPO_SOURCE_DIR else "github")
    return repo


def provider_env() -> dict[str, str]:
    if MODEL_PROVIDER == "bedrock":
        return {"CLAUDE_CODE_USE_BEDROCK": "1"}
    if MODEL_PROVIDER == "anthropic":
        import boto3

        # Lo lee el runtime; el modelo nunca lo ve (no tiene comandos para leer env).
        key = boto3.client("secretsmanager", region_name=REGION).get_secret_value(
            SecretId=ANTHROPIC_KEY_SECRET_ARN
        )["SecretString"].strip()
        return {"ANTHROPIC_API_KEY": key, "CLAUDE_CODE_USE_BEDROCK": ""}
    return {"CLAUDE_CODE_USE_BEDROCK": ""}  # local: la sesión de Claude Code de la máquina


def build_options(repo: Path | None) -> ClaudeAgentOptions:
    allowed = ["Read", "Grep", "Glob", *AWS_READ_TOOLS, *(REPO_EDIT_TOOLS if repo else [])]
    # Sin subagentes: si algo se le niega, que no intente pedírselo a otro agente.
    disallowed = ["Agent", "Task", "NotebookEdit", "WebFetch", "WebSearch"] + ([] if repo else ["Write", "Edit"])
    return ClaudeAgentOptions(
        system_prompt=load_runbook(),
        model=MODEL_ID,
        allowed_tools=allowed,
        disallowed_tools=disallowed,
        permission_mode="dontAsk",  # sin humano: toda petición no listada se DENIEGA
        max_turns=MAX_TURNS,
        max_budget_usd=MAX_BUDGET_USD,
        output_format={"type": "json_schema", "schema": DIAGNOSIS_SCHEMA},
        # Sin CLAUDE.md, settings ni MCP del entorno (ni del repo clonado): todo
        # lo que el agente sabe está en el runbook y en el prompt.
        setting_sources=[],
        # Sin atribución automática en commits/PRs (además del filtro del runtime).
        settings=json.dumps({"includeCoAuthoredBy": False, "attribution": {"commit": "", "pr": ""}}),
        cwd=str(repo or HERE),
        env={
            **provider_env(),
            "AWS_REGION": REGION,
            "AWS_DEFAULT_REGION": REGION,
            # Todos los alias de Claude Code apuntan al mismo modelo: una sola
            # suscripción en Bedrock y un solo modelo en la medición de costo.
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": MODEL_ID,
            "ANTHROPIC_DEFAULT_SONNET_MODEL": MODEL_ID,
            "ANTHROPIC_DEFAULT_OPUS_MODEL": MODEL_ID,
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "AWS_PAGER": "",
        },
    )


def build_prompt(event: dict[str, Any], repo: Path | None) -> str:
    repo_line = (
        f"- Repo con el contrato y la validación del pipeline, clonado en el directorio actual ({GITHUB_REPO}), rama propia. "
        "Si la causa es un cambio de schema, implementa el arreglo según el runbook (sección 'Proponer el arreglo').\n"
        if repo
        else "- No hay repo disponible en esta corrida: solo diagnostica (deja pr_titulo y pr_descripcion vacíos).\n"
    )
    return (
        "Una ejecución del pipeline terminó en FAILED. Este es el evento de EventBridge:\n\n"
        f"```json\n{json.dumps(event, indent=2, ensure_ascii=False)}\n```\n\n"
        "Datos del entorno:\n"
        f"- Log group del pipeline: {PIPELINE_LOG_GROUP}\n"
        f"- Bucket meta (manifests): s3://{META_BUCKET}/runs/run_id=<run_id>/manifest.json\n"
        f"- Bucket de cuarentena: s3://{QUARANTINE_BUCKET}/\n"
        f"{repo_line}\n"
        "Sigue el runbook. Tu respuesta final es el JSON del diagnóstico."
    )


def changed_files(repo: Path) -> list[str]:
    files = set(git(repo, "diff", "--name-only").split())
    files |= set(git(repo, "ls-files", "--others", "--exclude-standard").split())
    return sorted(files)


def github_api(path: str, token: str, body: dict[str, Any]) -> dict[str, Any]:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{GITHUB_REPO}/{path}",
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read())


def open_pull_request(repo: Path, branch: str, diagnosis: dict[str, Any], run: dict[str, Any]) -> dict[str, Any]:
    """Acciones con efecto, en código determinístico. Devuelve qué pasó."""
    files = changed_files(repo)
    if not files:
        return {"status": "sin_cambios"}
    outside = [f for f in files if not f.startswith(EDITABLE_PREFIXES)]
    if outside:
        # Guardrail determinístico: ni siquiera se commitea.
        return {"status": "bloqueado", "fuera_de_alcance": outside}

    title = (diagnosis.get("pr_titulo") or f"fix: {diagnosis['causa']}")[:120]
    git(repo, "add", "--", *files)
    git(repo, "-c", "user.name=demo-agent", "-c", "user.email=demo-agent@users.noreply.github.com",
        "commit", "--quiet", "-m", f"{title} [skip ci]" if SKIP_CI else title,
        "-m", "Propuesto por el agente de monitoreo (AgentCore). Draft: requiere revisión humana.")
    diff = git(repo, "show", "--stat", "--format=", "HEAD").strip()

    if PR_DRY_RUN or REPO_SOURCE_DIR:
        log("pr_dry_run", branch=branch, files=files, stat=diff, patch=git(repo, "show", "--format=", "HEAD")[:6000])
        return {"status": "dry_run", "files": files}

    token = github_token()
    push_url = f"https://x-access-token:{token}@github.com/{GITHUB_REPO}.git"
    git(repo, "push", "--quiet", push_url, f"HEAD:refs/heads/{branch}")
    body = "\n".join([
        "> **Draft abierto por el agente de monitoreo.**",
        "> El agente propone; una persona revisa, corre los tests y decide el merge.",
        "",
        diagnosis.get("pr_descripcion") or diagnosis["fix_propuesto"],
        "",
        "### Diagnóstico",
        f"**Causa:** {diagnosis['causa']}",
        "",
        *[f"- {e}" for e in diagnosis.get("evidencia", [])],
        "",
        f"`run_id`: `{diagnosis.get('run_id', '')}` · turnos: {run.get('num_turns')} · "
        f"costo del agente: ${run.get('total_cost_usd')}",
        "",
        "_El CI corre los tests de este PR; el merge lo decide una persona._" if not SKIP_CI
        else "_Commit con `[skip ci]`: el CI no corre hasta que una persona lo active._",
    ])
    pr = github_api("pulls", token, {"title": title, "head": branch, "base": "main", "body": body, "draft": True})
    log("pr_opened", url=pr.get("html_url"), number=pr.get("number"), files=files)
    return {"status": "abierto", "url": pr.get("html_url"), "files": files}


def publish(diagnosis: dict[str, Any], pr: dict[str, Any], execution_name: str) -> None:
    if not TOPIC_ARN:
        log("publish_skipped", reason="DIAGNOSIS_TOPIC_ARN vacío")
        return
    import boto3

    lines = [
        f"CAUSA: {diagnosis['causa']}",
        "",
        "EVIDENCIA:",
        *[f"  - {e}" for e in diagnosis.get("evidencia", [])],
        "",
        f"FIX PROPUESTO: {diagnosis['fix_propuesto']}",
        f"REQUIERE HUMANO: {'sí' if diagnosis.get('requiere_humano') else 'no'}",
        f"RUN_ID: {diagnosis.get('run_id', '')}",
        "",
    ]
    if pr.get("url"):
        lines += [f"PULL REQUEST (draft, para tu revisión): {pr['url']}"]
    elif pr.get("status") == "bloqueado":
        lines += [f"PR BLOQUEADO por el runtime: el agente tocó rutas fuera de alcance {pr.get('fuera_de_alcance')}"]
    subject = f"Diagnostico evtpipe-dev: {execution_name}"[:99]
    boto3.client("sns", region_name=REGION).publish(
        TopicArn=TOPIC_ARN, Subject=subject, Message="\n".join(lines)
    )
    log("published", subject=subject, pr=pr.get("url"))


async def _run_agent(event: dict[str, Any], repo: Path | None, on_result: Any) -> None:
    """El loop del agente: loguea cada paso y entrega el ResultMessage."""
    async for message in query(prompt=build_prompt(event, repo), options=build_options(repo)):
        if isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, TextBlock) and block.text.strip():
                    log("agent_text", text=block.text.strip()[:2000])
                elif isinstance(block, ToolUseBlock):
                    shown = block.input if block.name not in ("Edit", "Write") else {
                        "file_path": block.input.get("file_path")}
                    log("tool_use", tool=block.name, input=shown)
        elif isinstance(message, UserMessage) and isinstance(message.content, list):
            for block in message.content:
                if isinstance(block, ToolResultBlock):
                    text = json.dumps(block.content, default=str) if block.content else ""
                    log("tool_result", ok=not block.is_error, preview=text[:600])
        elif isinstance(message, ResultMessage):
            on_result(message)


async def diagnose(event: dict[str, Any]) -> dict[str, Any]:
    """Corre el agente sobre un evento y devuelve diagnóstico, PR y métricas."""
    started = time.time()
    execution_arn = event.get("detail", {}).get("executionArn", "?")
    execution_name = execution_arn.rsplit(":", 1)[-1]
    branch = f"agent/fix-{execution_name}"[:100]
    log("agent_start", execution_arn=execution_arn, model=MODEL_ID, provider=MODEL_PROVIDER, max_turns=MAX_TURNS,
        max_budget_usd=MAX_BUDGET_USD, pr_enabled=PR_ENABLED)

    repo = None
    try:
        repo = prepare_repo(branch)
    except Exception as exc:  # sin repo, el diagnóstico igual sale
        log("repo_unavailable", error=str(exc)[:300])

    results: list[ResultMessage] = []
    result: ResultMessage | None = None
    failure: str | None = None
    try:
        await _run_agent(event, repo, lambda r: results.append(r))
    except Exception as exc:  # el correo sale igual: "requiere humano" con el error
        failure = f"{type(exc).__name__}: {exc}"[:1500]
        log("agent_error", error=failure)
    result = results[-1] if results else None
    diagnosis = result.structured_output if result else None
    if not isinstance(diagnosis, dict):
        # Sin salida estructurada (presupuesto o turnos agotados): se escala.
        diagnosis = {
            "causa": "El agente no completó el diagnóstico.",
            "evidencia": [failure or f"subtype={result.subtype if result else '?'}",
                          ((result.result or "") if result else "")[:1500]],
            "fix_propuesto": f"Revisar manualmente la ejecución {execution_arn}.",
            "requiere_humano": True,
            "run_id": "",
        }

    diagnosis = limpiar(diagnosis)

    run = {
        "subtype": result.subtype if result else "exception",
        "is_error": result.is_error if result else True,
        "num_turns": result.num_turns if result else 0,
        "duration_ms": result.duration_ms if result else None,
        "total_cost_usd": result.total_cost_usd if result else None,
        "permission_denials": [str(d) for d in ((result.permission_denials or []) if result else [])],
        "error": failure,
    }

    pr: dict[str, Any] = {"status": "deshabilitado"}
    if repo is not None:
        try:
            pr = open_pull_request(repo, branch, diagnosis, run)
        except Exception as exc:
            pr = {"status": "error", "error": str(exc)[:300]}
    publish(diagnosis, pr, execution_name)

    run["wall_clock_s"] = round(time.time() - started, 1)
    # Esta línea es la que se copia a MEDICIONES.md.
    log("agent_result", execution_arn=execution_arn, diagnosis=diagnosis, pr=pr, **run)
    return {"diagnosis": diagnosis, "pr": pr, "run": run}


def dry_run(event: dict[str, Any]) -> int:
    """Valida la imagen sin modelo ni AWS: runbook, prompt, opciones y binarios."""
    global MODEL_PROVIDER
    MODEL_PROVIDER = "local"  # el dry-run no lee secretos ni llama al modelo
    options = build_options(None)
    runbook = load_runbook()
    from claude_agent_sdk._internal.transport.subprocess_cli import SubprocessCLITransport

    transport = SubprocessCLITransport(prompt="", options=options)
    cli = transport._cli_path or transport._find_cli()
    checks = {
        "claude": subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=60),
        "aws": subprocess.run(["aws", "--version"], capture_output=True, text=True, timeout=60),
        "git": subprocess.run(["git", "--version"], capture_output=True, text=True, timeout=60),
    }
    log(
        "dry_run",
        runbook_chars=len(runbook),
        runbook_title=runbook.splitlines()[0],
        model=options.model,
        permission_mode=options.permission_mode,
        allowed_tools=options.allowed_tools,
        pr_enabled=PR_ENABLED,
        max_turns=options.max_turns,
        max_budget_usd=options.max_budget_usd,
        claude_cli=cli,
        versions={k: (v.stdout or v.stderr).strip() for k, v in checks.items()},
        prompt_preview=build_prompt(event, None)[:400],
    )
    return 0 if all(v.returncode == 0 for v in checks.values()) else 1


def serve_agentcore() -> None:
    """Runtime AgentCore: el mismo diagnose() detrás del contrato HTTP de AgentCore."""
    from bedrock_agentcore.runtime import BedrockAgentCoreApp

    app = BedrockAgentCoreApp()

    @app.entrypoint
    async def invoke(payload: dict[str, Any]) -> dict[str, Any]:
        event = payload.get("event", payload)
        if payload.get("dry_run"):
            return {"dry_run": dry_run(event) == 0}
        return await diagnose(event)

    app.run()


def read_event(path: str | None) -> dict[str, Any]:
    if path:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    raw = os.environ.get("EVENT_JSON")
    if not raw:
        sys.exit("falta el evento: define EVENT_JSON o usa --event archivo.json")
    return json.loads(raw)


def main() -> int:
    if os.environ.get("AGENT_MODE") == "agentcore":
        serve_agentcore()
        return 0
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", help="archivo JSON con el evento de EventBridge")
    parser.add_argument("--dry-run", action="store_true", help="validar sin modelo ni AWS")
    args = parser.parse_args()
    event = read_event(args.event)
    if args.dry_run or os.environ.get("DRY_RUN") == "1":
        return dry_run(event)
    outcome = asyncio.run(diagnose(event))
    return 0 if not outcome["run"]["is_error"] else 1


if __name__ == "__main__":
    sys.exit(main())
