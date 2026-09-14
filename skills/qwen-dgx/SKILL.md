---
name: qwen-dgx
description: Delegate implementation work to a self-hosted Qwen model (via omp) so Claude only plans, briefs, reviews, and verifies. Use for well-scoped coding tasks - implement a function/component from a spec, mechanical refactors, writing tests, fixing a diagnosed bug, porting, boilerplate. Trigger on /qwen-dgx, "hand this to qwen", "use the dgx model", "save tokens on this", or when a task is implementation-heavy but design-light.
---

# qwen-dgx

Claude thinks and orchestrates. The self-hosted worker (`omp -p` against an OpenAI-compatible endpoint, free tokens) does the typing. The wrapper script is `run.sh` in this skill's base directory (shown above this text).

Task from the user: $ARGUMENTS

## Workflow

1. **Understand first.** Read the relevant code yourself. Decide the design, file layout, names, and acceptance criteria. The worker must not make product or architecture decisions.
2. **Write a brief** to a file in the scratchpad (`brief-<slug>.md`) using the template below. Be literal: exact paths, exact function signatures, exact behavior, exact verification command. Treat the worker as competent but context-free. Never put secrets in a brief.
3. **Run it**:
   ```bash
   <skill base directory>/run.sh -f /path/to/brief.md
   ```
   Use `run_in_background` for anything over about a minute. Set `QWEN_DGX_CWD=<repo>` if the target is not the current directory, `QWEN_DGX_TIMEOUT=45m` for big tasks. Independent tasks touching disjoint files may run in parallel (separate briefs, separate run.sh calls). A worker whose diff is complete but whose process idles for minutes can be killed; verify its work yourself.
4. **Review like a code reviewer.** Read the worker's REPORT and the full `git diff`. Run the verification command yourself. Do not trust the worker's claim that tests pass.
5. **Repair.** Small misses: fix directly. Larger misses: write a follow-up brief that quotes the current diff and states exactly what is wrong. Never let a wrong diff sit in the tree; `git checkout -- <files>` if a run must be discarded.
6. **Report to the user**: what was delegated, what the worker changed, what you verified, what you fixed by hand.

## Brief template

```
TASK: <one sentence>
REPO: <absolute path>   BRANCH/STATE: <clean or list of dirty files to leave alone>

CONTEXT
- <what the code does, the pattern to follow, file:line references>
- <constraints: language version, style, libs already installed, no new deps>

CHANGES
1. <path> - <exact change, signatures, behavior, edge cases>
2. ...

DO NOT
- commit, push, touch <paths>, add dependencies, reformat unrelated code

VERIFY
- run: <exact command>  expected: <what passing looks like>
```

## What to delegate vs keep

Delegate: implementation from a clear spec, tests for existing code, mechanical refactors and renames across files, porting, data plumbing, docs from code, bug fixes once Claude has diagnosed the root cause.

Keep in Claude: diagnosis, architecture, API and UX decisions, anything touching security or money without a precise spec, anything needing browser/visual verification (Claude verifies; the worker may still implement).

## Configuration

`run.sh` reads `QWEN_DGX_ENDPOINT` and `QWEN_DGX_MODEL` from the environment or from `~/.config/qwen-dgx/config` (written by `scripts/setup.sh` in the plugin). Worker rules (no commits, scope discipline, end with REPORT) are injected by run.sh. Logs land in `~/.omp/qwen-dgx/*.log`. The script exits 3 if the endpoint is unreachable and 4 if omp is missing.
