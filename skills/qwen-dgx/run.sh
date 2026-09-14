#!/usr/bin/env bash
# qwen-dgx: hand a coding task to a self-hosted model through omp, non-interactively.
# usage: run.sh "task text"        run.sh -f brief.md        echo "task" | run.sh
# config precedence: environment > ~/.config/qwen-dgx/config > built-in defaults
#   QWEN_DGX_ENDPOINT  OpenAI-compatible base URL, e.g. http://100.97.81.20:8888/v1
#   QWEN_DGX_MODEL     omp model reference, e.g. dgx/qwen3.8-27b-sglang
#   QWEN_DGX_CWD       repo to work in (default: current directory)
#   QWEN_DGX_TIMEOUT   omp --max-time value (default 20m)
set -uo pipefail

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/qwen-dgx/config"
[ -f "$CONFIG" ] && { set -a; . "$CONFIG"; set +a; }
ENDPOINT="${QWEN_DGX_ENDPOINT:-http://100.97.81.20:8888/v1}"
MODEL="${QWEN_DGX_MODEL:-dgx/qwen3.8-27b-sglang}"
CWD="${QWEN_DGX_CWD:-$PWD}"
TIMEOUT="${QWEN_DGX_TIMEOUT:-20m}"
LOGDIR="$HOME/.omp/qwen-dgx"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/$(date +%Y%m%d-%H%M%S)-$$.log"

if [ "${1:-}" = "-f" ]; then TASK="$(cat "$2")"
elif [ $# -gt 0 ]; then TASK="$*"
else TASK="$(cat)"; fi
[ -n "$TASK" ] || { echo "qwen-dgx: empty task" >&2; exit 2; }
exec </dev/null   # omp -p hangs at startup on an inherited non-tty stdin

command -v omp >/dev/null || { echo "qwen-dgx: omp is not installed or not on PATH. See the plugin README." >&2; exit 4; }
curl -sf --max-time 5 "${ENDPOINT%/}/models" >/dev/null || { echo "qwen-dgx: endpoint unreachable at $ENDPOINT (VPN/Tailscale up? model server running?)" >&2; exit 3; }

RULES='You are a worker executing a delegated task in this repository. Rules: do exactly the task, nothing more. Never git commit, push, stash, or reset. Do not touch files outside the task scope. Run the verification the task names (or the nearest existing test/typecheck) before finishing. End with a short REPORT: files changed, verification run and its result, anything you could not do and why.'

echo "qwen-dgx: model=$MODEL cwd=$CWD log=$LOG" >&2
omp -p --no-session --auto-approve --model "$MODEL" --cwd "$CWD" --max-time "$TIMEOUT" \
    --append-system-prompt "$RULES" "$TASK" 2>&1 | grep -v '^Working\.\.\.$' | tee "$LOG"
RC=${PIPESTATUS[0]}

if git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo; echo "=== git status ($CWD)"; git -C "$CWD" status --short; git -C "$CWD" diff --stat
fi
echo "=== exit $RC, log $LOG"
exit "$RC"
