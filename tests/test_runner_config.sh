#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REAL_PYTHON="$(command -v python3)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwen-dgx-runner-test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

chmod +x "$ROOT/tests/fixtures/bin/python3" "$ROOT/tests/fixtures/bin/omp"

run_case() {
  local model_override="$1"
  local endpoint_override="${2:-}"
  local args_file="$TMP_DIR/args"
  local discovery_env="$TMP_DIR/discovery-env"
  local config_dir="$TMP_DIR/config"
  rm -f "$args_file" "$discovery_env"
  rm -rf "$config_dir"
  mkdir -p "$config_dir/qwen-dgx"
  cp "$ROOT/tests/fixtures/config/qwen-dgx/config" "$config_dir/qwen-dgx/config"
  printf 'QWEN_DGX_SSH_IDENTITY=%s\n' "$ROOT/tests/fixtures/dgx-key" >> "$config_dir/qwen-dgx/config"
  PATH="$ROOT/tests/fixtures/bin:$PATH" \
  XDG_CONFIG_HOME="$config_dir" \
  QWEN_DGX_LOGDIR="$TMP_DIR/logs" \
  QWEN_DGX_CWD="$ROOT" \
  QWEN_DGX_REAL_PYTHON="$REAL_PYTHON" \
  QWEN_DGX_TEST_OMP_ARGS="$args_file" \
  QWEN_DGX_TEST_DISCOVERY_ENV="$discovery_env" \
  FAKE_DISCOVER_PATH="$ROOT/scripts/discover.py" \
  FAKE_ENDPOINT="http://fresh.example:2345/v1" \
  FAKE_MODEL="fresh-model" \
  QWEN_DGX_ENDPOINT="$endpoint_override" \
  QWEN_DGX_MODEL="$model_override" \
  "$ROOT/skills/qwen-dgx/run.sh" "offline test" >/dev/null

  test "$(sed -n '1p' "$discovery_env")" = "$endpoint_override"
  if [ -n "$model_override" ]; then
    test "$(sed -n '2p' "$discovery_env")" = "$model_override"
  else
    test "$(sed -n '2p' "$discovery_env")" = ""
  fi
  test "$(sed -n '3p' "$discovery_env")" = "$ROOT/tests/fixtures/dgx-key"
}

run_case ""
grep -Fqx 'dgx/fresh-model' "$TMP_DIR/args"
run_case "raw-model"
grep -Fqx 'dgx/raw-model' "$TMP_DIR/args"
run_case "explicit-model" "http://explicit.example:3456/v1"
grep -Fqx 'dgx/explicit-model' "$TMP_DIR/args"
echo "runner config precedence and model prefix checks passed"
