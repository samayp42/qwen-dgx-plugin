# qwen-dgx

Delegate implementation work from Claude Code or Codex to a model running on a configured DGX host. The plugin discovers an OpenAI-compatible endpoint and the model it serves, then lets `omp` do the typing while the calling agent plans, reviews, and verifies.

It works with SGLang, vLLM, Ollama, llama.cpp, TGI, and other servers that expose `GET /v1/models`. It does not assume a model name or an inference port.

## What you need

1. `omp` (oh-my-pi) on your `PATH`.
2. SSH access to one configured DGX host, or an explicit OpenAI-compatible endpoint.
3. Claude Code or Codex with plugins enabled.

## Install

Claude Code:

```
/plugin marketplace add samayp42/qwen-dgx-plugin
/plugin install qwen-dgx@qwen-dgx-plugin
```

Codex can install the GitHub plugin directory containing `.codex-plugin/plugin.json` and `skills/`.

## Configure and discover

For a DGX host, set the SSH target and run setup once:

```bash
export QWEN_DGX_HOST=user@dgx-host
export QWEN_DGX_SSH_IDENTITY=~/.ssh/dgx
bash /path/to/qwen-dgx/scripts/setup.sh
```

The optional identity path must exist and be readable. Discovery passes it to SSH with `IdentitiesOnly=yes`, so only that configured key is attempted. Setup performs read-only SSH inspection of that host, keeps only listeners whose process metadata looks like a model server, probes each candidate with `GET /v1/models`, and registers the discovered endpoint/model for `omp`. It never probes or changes port `8000`.

If SSH discovery cannot see the service, provide explicit candidates instead:

```bash
QWEN_DGX_HOST=user@dgx-host \
QWEN_DGX_ENDPOINT_CANDIDATES='http://dgx-host:12345/v1,http://127.0.0.1:23456/v1' \
bash /path/to/qwen-dgx/scripts/setup.sh
```

The candidate list is opt-in. The plugin does not scan arbitrary hosts or ports. `QWEN_DGX_SSH_PORT` can select the configured SSH port when it is not the default.

Explicit endpoint and model overrides remain supported:

```bash
QWEN_DGX_ENDPOINT=https://dgx-host.example/v1 \
QWEN_DGX_MODEL=dgx/my-model \
bash /path/to/qwen-dgx/scripts/setup.sh
```

`QWEN_DGX_MODEL` may be a raw model ID during setup; it is registered under the `dgx` provider. At runtime, environment variables take precedence over `~/.config/qwen-dgx/config`.

Discovery uses bounded timeouts, does not follow HTTP redirects, reads at most 1 MiB from `/models`, and does not print response bodies. Endpoint URLs containing credentials or query parameters are rejected. The model endpoint must be reachable without HTTP authentication, for example over a private Tailscale network.

## Use

In Claude Code:

```
/qwen-dgx:qwen-dgx add a --dry-run flag to scripts/deploy.sh
```

Or say “hand this to qwen”. Codex can use the same `skills/qwen-dgx/SKILL.md` workflow.

Run the worker directly:

```bash
/path/to/qwen-dgx/skills/qwen-dgx/run.sh -f brief.md
QWEN_DGX_CWD=/path/to/repo /path/to/qwen-dgx/skills/qwen-dgx/run.sh "task text"
```

The runner repeats safe discovery before the worker starts, so a changed model or port is picked up when the configured endpoint or host is reachable. It builds a temporary `omp` provider file for that invocation, so the discovered endpoint is used without rewriting the user's global `omp` configuration. Setup also registers the provider for standalone `omp` use.

## Configuration

| Variable | Meaning |
| --- | --- |
| `QWEN_DGX_ENDPOINT` | Explicit OpenAI-compatible base URL, such as `https://host/v1` |
| `QWEN_DGX_MODEL` | Explicit `omp` model reference, such as `dgx/model-id` |
| `QWEN_DGX_HOST` | One configured SSH target used for read-only listener discovery |
| `QWEN_DGX_SSH_PORT` | SSH port for that host |
| `QWEN_DGX_SSH_IDENTITY` | Optional readable SSH private-key path for that host |
| `QWEN_DGX_ENDPOINT_CANDIDATES` | Comma/newline-separated explicit endpoint candidates |
| `QWEN_DGX_CWD` | Repository the worker edits |
| `QWEN_DGX_TIMEOUT` | `omp --max-time` value, default `20m` |
| `QWEN_DGX_LOGDIR` | Optional worker log directory, default `~/.omp/qwen-dgx` |

Environment values override the local config file. When `QWEN_DGX_HOST` is configured, the runner ignores the setup-cached endpoint/model and rediscovers the live listener; an endpoint/model supplied in the environment remains authoritative. The runner log contains the model reference, working directory, and task output, but not endpoint credentials.

## Safety boundaries

- Discovery is GET-only and read-only. SSH runs fixed `ss`/`netstat` and `ps` inspection commands without a user-provided shell fragment, and an optional identity is validated before being passed with `IdentitiesOnly=yes`.
- Only the configured DGX host and explicitly configured endpoint candidates are contacted.
- Port `8000` is reserved and rejected before any HTTP probe or SSH candidate use.
- No commits, pushes, stashes, resets, installs, or changes outside the delegated repository are performed by the worker.

## Verify

```bash
python3 tests/test_discover.py
bash tests/test_runner_config.sh
python3 -m py_compile scripts/discover.py
```

The tests are offline and cover model-list parsing, model-process listener filtering, SSH identity validation/flags, the protected-port guard, host rediscovery over stale setup values, and raw model-ID prefixing.

## Known limits

- SSH discovery relies on process names/arguments that identify a model server. A service with hidden or unusual process metadata must be supplied through `QWEN_DGX_ENDPOINT_CANDIDATES`.
- A model server bound only to remote loopback needs an existing tunnel or a user-configured reachable candidate. The plugin does not create tunnels.
- Direct `omp` use still needs a provider registration. Run setup again after changing the discovered server if the standalone provider's endpoint/model changed; the plugin runner refreshes its temporary provider each run.
