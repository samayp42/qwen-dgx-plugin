#!/usr/bin/env bash
# Discover one configured DGX model endpoint and register it for omp.
# usage: setup.sh [endpoint-base-url] [model-id]
# Without an endpoint, set QWEN_DGX_HOST to one SSH host for read-only discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENDPOINT_OVERRIDE="${1:-${QWEN_DGX_ENDPOINT:-}}"
MODEL_OVERRIDE="${2:-${QWEN_DGX_MODEL:-}}"
HOST="${QWEN_DGX_HOST:-}"
SSH_PORT="${QWEN_DGX_SSH_PORT:-}"
SSH_IDENTITY="${QWEN_DGX_SSH_IDENTITY:-}"
CANDIDATES="${QWEN_DGX_ENDPOINT_CANDIDATES:-${QWEN_DGX_CANDIDATES:-}}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/qwen-dgx"
CONFIG_FILE="$CONFIG_DIR/config"
OMP_MODELS="${QWEN_DGX_OMP_MODELS:-$HOME/.omp/agent/models.yml}"
PROVIDER=dgx

command -v omp >/dev/null || { echo "omp is not installed. Install it first, then rerun this script." >&2; exit 4; }
command -v python3 >/dev/null || { echo "python3 is required for safe model discovery." >&2; exit 4; }

DISCOVERY="$(
  QWEN_DGX_ENDPOINT="$ENDPOINT_OVERRIDE" \
  QWEN_DGX_MODEL="$MODEL_OVERRIDE" \
  QWEN_DGX_HOST="$HOST" \
  QWEN_DGX_SSH_PORT="$SSH_PORT" \
  QWEN_DGX_SSH_IDENTITY="$SSH_IDENTITY" \
  QWEN_DGX_ENDPOINT_CANDIDATES="$CANDIDATES" \
  python3 "$SCRIPT_DIR/discover.py"
)" || { echo "Endpoint discovery failed; set an explicit endpoint or configured DGX SSH host." >&2; exit 3; }
ENDPOINT="$(printf '%s\n' "$DISCOVERY" | sed -n '1p')"
MODEL_ID="$(printf '%s\n' "$DISCOVERY" | sed -n '2p')"
[ -n "$ENDPOINT" ] && [ -n "$MODEL_ID" ] || { echo "Discovery returned no endpoint/model." >&2; exit 3; }

if [ -n "$MODEL_OVERRIDE" ]; then
  case "$MODEL_OVERRIDE" in
    "$PROVIDER"/*) MODEL_REF="$MODEL_OVERRIDE" ;;
    *) MODEL_REF="$PROVIDER/$MODEL_OVERRIDE" ;;
  esac
else
  MODEL_REF="$PROVIDER/$MODEL_ID"
fi

# An explicit endpoint is authoritative for future runs, so do not persist a
# host that would intentionally trigger rediscovery over that endpoint.
CONFIG_HOST="$HOST"
[ -z "$ENDPOINT_OVERRIDE" ] || CONFIG_HOST=""

umask 077
mkdir -p "$CONFIG_DIR"
{
  printf 'QWEN_DGX_ENDPOINT=%s\n' "$ENDPOINT"
  printf 'QWEN_DGX_MODEL=%s\n' "$MODEL_REF"
  printf 'QWEN_DGX_HOST=%s\n' "$CONFIG_HOST"
  [ -z "$SSH_PORT" ] || printf 'QWEN_DGX_SSH_PORT=%s\n' "$SSH_PORT"
  [ -z "$SSH_IDENTITY" ] || printf 'QWEN_DGX_SSH_IDENTITY=%s\n' "$SSH_IDENTITY"
  [ -z "$CANDIDATES" ] || printf 'QWEN_DGX_ENDPOINT_CANDIDATES=%s\n' "$CANDIDATES"
} > "$CONFIG_FILE"
echo "Wrote $CONFIG_FILE"

OMP_ENDPOINT="$ENDPOINT" OMP_MODEL_ID="$MODEL_ID" OMP_MODELS_PATH="$OMP_MODELS" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

path = Path(os.environ["OMP_MODELS_PATH"])
endpoint = os.environ["OMP_ENDPOINT"]
model_id = os.environ["OMP_MODEL_ID"]
provider = "dgx"
quote = lambda value: json.dumps(value, ensure_ascii=False)
block = "\n".join(
    [
        f"  {provider}:",
        f"    baseUrl: {quote(endpoint)}",
        "    auth: none",
        "    api: openai-completions",
        "    models:",
        f"      - id: {quote(model_id)}",
        "        name: Model on configured DGX",
        "        input: [text]",
        "        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }",
    ]
)
text = path.read_text() if path.exists() else "providers:\n"
if not re.search(r"^providers:\s*$", text, re.MULTILINE):
    text = "providers:\n" + text
match = re.search(r"^  dgx:\s*$", text, re.MULTILINE)
if match:
    next_provider = re.search(r"^  \S.*:\s*$", text[match.end() :], re.MULTILINE)
    end = match.end() + next_provider.start() if next_provider else len(text)
    text = text[: match.start()] + block + "\n" + text[end:]
else:
    text = text.rstrip() + "\n" + block + "\n"
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(f".{path.name}.qwen-dgx.tmp")
tmp.write_text(text)
os.replace(tmp, path)
PY
echo "Updated omp provider '$PROVIDER' in $OMP_MODELS"

echo "Smoke test (expect PONG) ..."
omp -p --no-session --model "$MODEL_REF" --max-time 2m "Reply with exactly the word PONG and nothing else." </dev/null 2>&1 \
  | grep -v '^Working\.\.\.$' | tail -1
echo "Done. In Claude Code, use /qwen-dgx:qwen-dgx <task> (or say: hand this to qwen)."
