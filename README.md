# qwen-dgx

A Claude Code plugin that hands implementation work to a self-hosted model. Claude keeps the thinking: it reads the code, decides the design, writes a precise brief, then reviews the diff and reruns the tests. The self-hosted model (a Qwen on a DGX Spark in the original setup, but any OpenAI-compatible endpoint works) does the typing through [omp](https://github.com/can1357/oh-my-pi), so Claude tokens go to judgment, not output.

## What you need

1. **Network access to the model server.** The default endpoint is a DGX on a private Tailscale network. Ask the owner to share the machine with your tailnet (Tailscale admin console, Machines, Share) and confirm `curl http://100.97.81.20:8888/v1/models` answers from your laptop. Any other OpenAI-compatible server (vLLM, SGLang, llama.cpp, Ollama with `/v1`) works too; pass its URL to the setup script.
2. **omp** (oh-my-pi) on your PATH. It is the agent that edits files and runs commands on the model's behalf.
3. **Claude Code** with plugins enabled.

## Install

Inside Claude Code:

```
/plugin marketplace add samayp42/qwen-dgx-plugin
/plugin install qwen-dgx@qwen-dgx-plugin
```

Then, in a terminal, run the setup once (endpoint and model id are optional; the defaults point at the shared DGX):

```
bash ~/.claude/plugins/cache/qwen-dgx-plugin/qwen-dgx/*/scripts/setup.sh [http://host:port/v1] [model-id]
```

It records the endpoint in `~/.config/qwen-dgx/config`, registers a `dgx` provider in omp, and runs a PONG smoke test.

## Use

In Claude Code:

```
/qwen-dgx:qwen-dgx add a --dry-run flag to scripts/deploy.sh
```

or just say "hand this to qwen" or "save tokens on this". Claude writes a brief, runs the worker, reviews the diff, reruns verification, and reports what it fixed by hand. Good candidates: building from a clear spec, tests for existing code, mechanical refactors, porting, plumbing, bug fixes once the cause is known. Keep diagnosis, architecture and UX judgment with Claude.

Run the worker directly from a shell:

```
~/.claude/plugins/cache/qwen-dgx-plugin/qwen-dgx/*/skills/qwen-dgx/run.sh -f brief.md
QWEN_DGX_CWD=/path/to/repo QWEN_DGX_TIMEOUT=45m .../run.sh "task text"
```

## Configuration

| Variable | Meaning | Default |
| --- | --- | --- |
| `QWEN_DGX_ENDPOINT` | OpenAI-compatible base URL | `http://100.97.81.20:8888/v1` |
| `QWEN_DGX_MODEL` | omp model reference `provider/id` | `dgx/qwen3.8-27b-sglang` |
| `QWEN_DGX_CWD` | repository the worker edits | current directory |
| `QWEN_DGX_TIMEOUT` | omp `--max-time` | `20m` |

Environment variables win over `~/.config/qwen-dgx/config`. Logs: `~/.omp/qwen-dgx/`.

## Safety rules the worker is given

No commits, pushes, stashes or resets. No edits outside the task's scope. Run the named verification before finishing. End with a REPORT of files changed, checks run, and anything blocked. Claude still re-verifies everything.

## Known limits

- The worker only sees what the brief and the repo tell it. Vague briefs produce vague work.
- Runs take minutes, not seconds. Use Claude's background execution for long jobs.
- omp occasionally idles after finishing; if the diff is complete, it is safe to stop the process.
