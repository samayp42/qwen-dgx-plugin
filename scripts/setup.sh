#!/usr/bin/env bash
# One-time setup for the qwen-dgx plugin: records the endpoint, registers it in omp, smoke-tests it.
# usage: setup.sh [endpoint-base-url] [model-id]
set -euo pipefail
ENDPOINT="${1:-${QWEN_DGX_ENDPOINT:-http://100.97.81.20:8888/v1}}"
MODEL_ID="${2:-qwen3.8-27b-sglang}"
PROVIDER=dgx
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/qwen-dgx"
OMP_MODELS="$HOME/.omp/agent/models.yml"

command -v omp >/dev/null || { echo "omp is not installed. Install it first (see README), then rerun this script." >&2; exit 4; }
echo "Checking $ENDPOINT ..."
curl -sf --max-time 8 "${ENDPOINT%/}/models" | head -c 200 || { echo; echo "Endpoint unreachable. Are you on the Tailscale network that hosts the DGX?" >&2; exit 3; }
echo

mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config" <<CFG
QWEN_DGX_ENDPOINT=$ENDPOINT
QWEN_DGX_MODEL=$PROVIDER/$MODEL_ID
CFG
echo "Wrote $CONFIG_DIR/config"

mkdir -p "$(dirname "$OMP_MODELS")"
if [ -f "$OMP_MODELS" ] && grep -qE "^\s*$PROVIDER:" "$OMP_MODELS"; then
  echo "omp already has a '$PROVIDER' provider in $OMP_MODELS; leaving it alone."
else
  [ -f "$OMP_MODELS" ] && grep -qE '^providers:' "$OMP_MODELS" || printf 'providers:\n' >> "$OMP_MODELS"
  cat >> "$OMP_MODELS" <<YML
  $PROVIDER:
    baseUrl: $ENDPOINT
    auth: none
    api: openai-completions
    models:
      - id: $MODEL_ID
        name: Qwen on DGX
        reasoning: true
        input: [text, image]
        tokenizer: qwen3
        contextWindow: 262144
        maxTokens: 32768
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
YML
  echo "Registered provider '$PROVIDER' in $OMP_MODELS"
fi

echo "Smoke test (expect PONG) ..."
omp -p --no-session --model "$PROVIDER/$MODEL_ID" --max-time 2m "Reply with exactly the word PONG and nothing else." </dev/null 2>&1 | grep -v '^Working\.\.\.$' | tail -1
echo "Done. In Claude Code, use /qwen-dgx:qwen-dgx <task> (or say: hand this to qwen)."
