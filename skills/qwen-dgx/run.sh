#!/usr/bin/env bash
# qwen-dgx: hand a coding task to a discovered OpenAI-compatible model through omp.
# usage: run.sh "task text"        run.sh -f brief.md        echo "task" | run.sh
# config precedence: environment > ~/.config/qwen-dgx/config
#   QWEN_DGX_ENDPOINT             explicit OpenAI-compatible base URL
#   QWEN_DGX_MODEL                explicit omp model reference
#   QWEN_DGX_HOST                 configured SSH host for read-only discovery
#   QWEN_DGX_SSH_IDENTITY         optional readable SSH private-key path
#   QWEN_DGX_ENDPOINT_CANDIDATES  comma/newline-separated explicit candidates
#   QWEN_DGX_CWD                  repo to work in (default: current directory)
#   QWEN_DGX_TIMEOUT              omp --max-time value (default 20m)
#   QWEN_DGX_LOGDIR               worker log directory (default ~/.omp/qwen-dgx)
set -uo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/qwen-dgx/config"
DISCOVER="$(cd "$(dirname "$0")/../../scripts" && pwd)/discover.py"
CONFIG_ENDPOINT=""
CONFIG_MODEL=""
CONFIG_HOST=""
CONFIG_SSH_PORT=""
CONFIG_SSH_IDENTITY=""
CONFIG_CANDIDATES=""
if [ -f "$CONFIG" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      QWEN_DGX_ENDPOINT) CONFIG_ENDPOINT="$value" ;;
      QWEN_DGX_MODEL) CONFIG_MODEL="$value" ;;
      QWEN_DGX_HOST) CONFIG_HOST="$value" ;;
      QWEN_DGX_SSH_PORT) CONFIG_SSH_PORT="$value" ;;
      QWEN_DGX_SSH_IDENTITY) CONFIG_SSH_IDENTITY="$value" ;;
      QWEN_DGX_ENDPOINT_CANDIDATES|QWEN_DGX_CANDIDATES) CONFIG_CANDIDATES="$value" ;;
    esac
  done < "$CONFIG"
fi
ENDPOINT_OVERRIDE="${QWEN_DGX_ENDPOINT:-$CONFIG_ENDPOINT}"
MODEL_OVERRIDE="${QWEN_DGX_MODEL:-$CONFIG_MODEL}"
HOST="${QWEN_DGX_HOST:-$CONFIG_HOST}"
SSH_PORT="${QWEN_DGX_SSH_PORT:-$CONFIG_SSH_PORT}"
SSH_IDENTITY="${QWEN_DGX_SSH_IDENTITY:-$CONFIG_SSH_IDENTITY}"
CANDIDATES="${QWEN_DGX_ENDPOINT_CANDIDATES:-${QWEN_DGX_CANDIDATES:-$CONFIG_CANDIDATES}}"
if [ -n "$HOST" ]; then
  # A configured host is the source of truth; setup's cached endpoint/model
  # must not hide a listener or model change on that host.
  ENDPOINT_OVERRIDE="${QWEN_DGX_ENDPOINT:-}"
  MODEL_OVERRIDE="${QWEN_DGX_MODEL:-}"
fi
CWD="${QWEN_DGX_CWD:-$PWD}"
TIMEOUT="${QWEN_DGX_TIMEOUT:-20m}"
LOGDIR="${QWEN_DGX_LOGDIR:-$HOME/.omp/qwen-dgx}"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(date +%Y%m%d-%H%M%S)-$$.log"

if [ "${1:-}" = "-f" ]; then TASK="$(cat "$2")"
elif [ $# -gt 0 ]; then TASK="$*"
else TASK="$(cat)"; fi
[ -n "$TASK" ] || { echo "qwen-dgx: empty task" >&2; exit 2; }
exec </dev/null   # omp -p hangs at startup on an inherited non-tty stdin

command -v omp >/dev/null || { echo "qwen-dgx: omp is not installed or not on PATH. See the plugin README." >&2; exit 4; }
command -v python3 >/dev/null || { echo "qwen-dgx: python3 is required for safe model discovery." >&2; exit 4; }

DISCOVERY="$(
  QWEN_DGX_ENDPOINT="$ENDPOINT_OVERRIDE" \
  QWEN_DGX_MODEL="$MODEL_OVERRIDE" \
  QWEN_DGX_HOST="$HOST" \
  QWEN_DGX_SSH_PORT="$SSH_PORT" \
  QWEN_DGX_SSH_IDENTITY="$SSH_IDENTITY" \
  QWEN_DGX_ENDPOINT_CANDIDATES="$CANDIDATES" \
  python3 "$DISCOVER"
)" || { echo "qwen-dgx: model discovery failed; set a valid endpoint/model or configured DGX host." >&2; exit 3; }
ENDPOINT="$(printf '%s\n' "$DISCOVERY" | sed -n '1p')"
MODEL_ID="$(printf '%s\n' "$DISCOVERY" | sed -n '2p')"
[ -n "$ENDPOINT" ] && [ -n "$MODEL_ID" ] || { echo "qwen-dgx: discovery returned no endpoint/model." >&2; exit 3; }
case "$MODEL_OVERRIDE" in
  dgx/*) MODEL="$MODEL_OVERRIDE" ;;
  "") MODEL="dgx/$MODEL_ID" ;;
  *) MODEL="dgx/$MODEL_OVERRIDE" ;;
esac

# Keep the discovered endpoint/model isolated to this invocation. This avoids
# rewriting a user's omp config and guarantees that a changed DGX listener is
# the endpoint actually used by the worker.
AGENT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwen-dgx-agent.XXXXXX")" || {
  echo "qwen-dgx: could not create a temporary omp config." >&2
  exit 3
}
trap 'rm -rf -- "$AGENT_DIR"' EXIT
OMP_ENDPOINT="$ENDPOINT" OMP_MODEL_ID="$MODEL_ID" OMP_AGENT_DIR="$AGENT_DIR" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["OMP_AGENT_DIR"]) / "models.yml"
quote = lambda value: json.dumps(value, ensure_ascii=False)
path.write_text(
    "\n".join(
        [
            "providers:",
            "  dgx:",
            f"    baseUrl: {quote(os.environ['OMP_ENDPOINT'])}",
            "    auth: none",
            "    api: openai-completions",
            "    models:",
            f"      - id: {quote(os.environ['OMP_MODEL_ID'])}",
            "        name: Model on configured DGX",
            "        input: [text]",
            "        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }",
            "",
        ]
    )
)
PY

RULES='You are a worker executing a delegated task in this repository. Rules: do exactly the task, nothing more. Never git commit, push, stash, or reset. Do not touch files outside the task scope. Run the verification the task names (or the nearest existing test/typecheck) before finishing. End with a short REPORT: files changed, verification run and its result, anything you could not do and why.'

echo "qwen-dgx: model=$MODEL cwd=$CWD log=$LOG" >&2
PI_CODING_AGENT_DIR="$AGENT_DIR" omp -p --no-session --auto-approve --model "$MODEL" --cwd "$CWD" --max-time "$TIMEOUT" \
    --append-system-prompt "$RULES" "$TASK" 2>&1 | grep -v '^Working\.\.\.$' | tee "$LOG"
RC=${PIPESTATUS[0]}

if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo; echo "=== git status ($CWD)"; git -C "$CWD" status --short; git -C "$CWD" diff --stat
fi
echo "=== exit $RC, log $LOG"
exit "$RC"
