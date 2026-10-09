# Configuración común de los scripts de la demo. Se carga con `source`.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON_DIR="$(dirname "$DEMO_DIR")"   # raíz de este repo
INFRA_DIR="$ADDON_DIR/infra"
# Solo happy_path.sh lo necesita: el checkout del pipeline (genera datos válidos + referencia).
PIPELINE_DIR="${PIPELINE_DIR:-}"
PIPELINE_PREFIX="${PIPELINE_PREFIX:-evtpipe-dev}"
STATE_MACHINE_NAME="$PIPELINE_PREFIX-pipeline"

TERRAFORM="$(command -v terraform || echo "$HOME/.local/bin/terraform")"
tf_out() { "$TERRAFORM" -chdir="$INFRA_DIR" output -raw "$1" 2>/dev/null || true; }

state_machine_arn() {
  aws stepfunctions list-state-machines \
    --query "stateMachines[?name=='$STATE_MACHINE_NAME'].stateMachineArn | [0]" --output text
}

say() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
