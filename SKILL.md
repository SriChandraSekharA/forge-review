---
name: forge-standard-review
description: "Quota-free iterative code review with continuous loop, architecture review, security review, vulnerability review, OWASP review, correctness review, readability review, performance review, code quality review, review loop, iterative review, multi reviewer, git diff review, standards review, spec review, SOLID review, learning memory, custom rules, blast radius, impact analysis - idempotent .forge-standard-review/ per-repo memory"
---

# Forge Standard Review

Quota-free iterative code review that runs entirely in your repository.

> No external service tokens or paid review credentials required - fully offline capable and quota-free.

## Overview

Forge Standard brings a disciplined, repeatable review pass to every change
without quotas, rate limits, or external dependencies. It operates as a
continuous loop with multiple reviewer perspectives, a ranked report, and
per-repo memory that persists across invocations.

Core principles:

- **Quota-free** - no API keys, no usage caps, no network gate.
- **Severity-cap score** - pure function of findings: critical caps 3, high 5, medium 7; only low/nitpick reach 8-10.
- **Hunk-aware findings** - real `path:line` resolved from diff hunk headers.
- **Real linters first** - ruff (Python), eslint (JS/TS) and gitleaks run when installed and keep only
  violations on lines this diff added; semgrep is opt-in (`FORGE_SEMGREP=1`) and network-aware because
  `--config auto` may fetch rules. Regex rules are the offline
  fallback and stand down only where a linter demonstrably covers the same problem. `--fix` applies the
  mechanical part; the rest stays with the reviewer.
- **Convergence stop** - loop halts when the finding set stops changing (iteration cap still configurable).
- **Ranked report** - findings ordered critical -> high -> medium -> low -> nitpick.
- **Learning memory** - dismissed findings, severity floors, and plain-English team rules persist per-repo and apply automatically on every run.
- **Blast radius** - importer/caller tracing beyond the diff feeds the report.
- **Idempotent memory** - per-repo `.forge-standard-review/` is created once and reused.
- **VCS-aware** - works with git, hg, or no VCS (degrades gracefully).

Use this skill when you need a thorough review before merging, when you want
iterative refinement until the gate passes, or when you want a repeatable
checklist that lives with the repo.

## Install

Global install (recommended):

```bash
npx skills add SriChandraSekharA/forge-review --skill forge-standard-review -g
```

Local project install:

```bash
npx skills add SriChandraSekharA/forge-review --skill forge-standard-review
```

Manual clone:

```bash
git clone https://github.com/SriChandraSekharA/forge-review.git
```

After install the skill is available as `forge-standard-review` via `npx skills add -l`.

## Contract

The skill follows a strict idempotent contract anchored at `.forge-standard-review/`:

1. **First invocation** - `init` creates `.forge-standard-review/` at the repo root
   with baseline config, checklist snapshot, knowledge fallback manifest, and
   empty learning memory (`feedback.jsonl`, `rules.md`).
2. **Reuse thereafter** - every subsequent invocation reads the existing
   `.forge-standard-review/` directory, reuses stored state, and updates only what
   changed (findings, iteration counter, timestamps).
3. **Never recreate blindly** - if `.forge-standard-review/` already exists, scripts
   do not overwrite user customizations; they merge or append.
4. **Per-repo isolation** - each repository owns its own `.forge-standard-review/`
   directory; no global state leaks between repos.
5. **Deterministic cleanup** - `report` consolidates findings without mutating
   source files; `review` may propose patches but requires explicit apply.

This contract guarantees the loop can be re-entered safely any number of times
without duplicating state or losing prior decisions.

### Memory files

| File | Semantics |
|------|-----------|
| `state.json` | manifest; `lastReviewAt` refreshed per invocation, CUSTOM blocks and reviews preserved via merge |
| `history.md` | git history snapshot per invocation |
| `learning.md` | iteration scores; append-only, never truncated on re-init |
| `test_context.md` | detected test files and discovery output |
| `checklist.md` / `knowledge.md` | checklist snapshot and knowledge fallback manifest |
| `feedback.jsonl` | learning memory - append-only JSONL of dismissed finding classes and severity floors (`learn.sh` writes, `review.sh` consumes); never rewritten, invalid lines skipped |
| `rules.md` | plain-English team rules - one `- <rule>` per line, `#` comments ignored; created by `init.sh`, preserved by `merge.sh` (exact-line dedupe union) |
| `report.md` / `review.json` | ranked report artifacts; `review.json` carries an additive `impact` array |
| `run-<ts>-<pid>.log` | per-run loop log (suppressions, fixes, gate status) |

## Prerequisites

- **git** - required for diff-range and staged review modes.
- **bash** - required to run scripts (`bash 4+` recommended, `zsh` also works).
- **jq** - optional but recommended for JSON report shaping and filtering.
  If `jq` is absent, reports fall back to plain text tables.

Verify before use:

```bash
git --version
bash --version
jq --version   # optional
```

## Usage

All scripts live under `scripts/` and are executable from the skill root or
via the installed skill path.

### 1. Initialize

```bash
./scripts/init.sh
```

Creates `.forge-standard-review/` on first run; on later runs validates and
updates the manifest. Safe to run repeatedly.

### 2. Review

```bash
./scripts/review.sh --staged
./scripts/review.sh --range HEAD~1..HEAD
./scripts/review.sh --range main...feature
./scripts/review.sh --file path/to/file.ts
```

Modes:

- `--staged` - review only staged changes (`git diff --cached`).
- `--range <ref>` - review a commit range or branch diff.
- `--file <path>` - review a single file regardless of VCS state.
- `--diff-file <patch>` - review a unified diff that already exists on disk (no working tree needed, nothing
  is applied or fixed). Used by the golden fixtures; linters only run on paths that exist, so a patch-only
  review falls back to the regex rules and says so in the run log.

Options:

- `--max-iterations N` - hard cap on loop iterations (default 8); the loop normally stops earlier, as soon as the
  finding set converges or the score reaches the gate.
- `--max-fixes N` - cap hint re-injections (and fix attempts when `--fix` is on) across the loop (default 4);
  when reached, the loop keeps iterating without injecting new hints.
- `--fix` - opt-in. Between iterations, run `ruff check --fix` / `eslint --fix` on the changed files and
  recompute the diff, so the next iteration reviews the FIXED code. A fix that changes nothing does not
  consume a budget slot, and everything a linter cannot fix (design, tests, architecture) stays manual.
- `--tests CMD` - run CMD (via `bash -c`) once per iteration after critic scoring; a non-zero exit injects one synthetic `[test/high]` finding plus the output tail so the loop reacts to test failures (no retries).

On every run the loop applies learned memory automatically: matching dismissals are suppressed, findings below the learned severity floor are dropped, and the run prints `learning: N suppressed (M below floor)` plus `rules: N active`.

### 3. Learn (feedback memory)

```bash
./scripts/learn.sh --dismiss --file <glob-or-path> --rule <regex> --reason <text>
./scripts/learn.sh --floor --severity <high|medium|low|nitpick> --reason <text>
./scripts/learn.sh --rule "<plain-English team rule>"
./scripts/learn.sh --rules    # list active team rules
./scripts/learn.sh --list     # list learned feedback
```

- `--dismiss` - record a dismissed finding class (path glob or literal + reason regex); deduped on path+rule.
- `--floor` - record a learned severity floor; findings strictly below it are dropped.
- `--rule` - append a plain-English team rule to `.forge-standard-review/rules.md` (exact-line dedupe).
- `--rules` / `--list` - print active team rules / learned feedback.

Memory is append-only JSONL - never rewritten or destroyed, invalid lines skipped. An optional trailing `TARGET_DIR` positional overrides the default script-relative repo root.

### 4. Impact (blast radius)

```bash
./scripts/impact.sh --files src/a.ts,src/b.ts
git diff --name-only main...HEAD | ./scripts/impact.sh   # one path per line on stdin
```

Local importer/caller tracing beyond the diff (`import`/`require`/`include`/`reference` kinds), capped at 50 matches per changed file and 200 total, then one `... N more` line. Prints `IMPACT none` when empty, always exits 0, and is safe without a VCS. `report.sh` integrates it automatically: a `## Impact (beyond the diff)` section appears in `report.md` before the ranked sections (omitted when none) and an additive `impact` array is written to `review.json` (backward compatible).

### 5. Report

```bash
./scripts/report.sh
./scripts/report.sh --format json
./scripts/report.sh --format markdown --output review.md
```

Generates the ranked report ordered critical -> high -> medium -> low -> nitpick, including the impact section and learned-rule coverage. No tokens, no external calls, no hidden uploads.

## Structure

```
forge-standard-review/
  SKILL.md                # this file - frontmatter + contract
  README.md               # install, features, license
  AGENTS.md               # contributor contract for this repo
  .gitignore              # ignores .forge-standard-review/, logs, caches
  scripts/
    init.sh               # idempotent .forge-standard-review/ bootstrap
    review.sh             # staged | range | file review loop (orchestrator)
    detect.sh             # detection engine: hunk-aware flattening, linters, local rules
    lint-normalize.py     # maps ruff/eslint/gitleaks/semgrep JSON onto findings
    autofix.sh            # --fix: apply the mechanical part via ruff/eslint
    critic.sh             # severity-cap score (pure function of findings)
    report.sh             # ranked report generator
    learn.sh              # feedback memory CLI (dismissals, severity floors, team rules)
    impact.sh             # blast-radius tracing beyond the diff
  references/
    checklist.md          # 6-axis checklist (correctness/readability/arch/security/perf/test coverage)
    knowledge.md          # fallback chain priority list
  templates/
    report.md             # markdown report template
    worker.prompt.md      # worker prompt with 6 axes including test quality
    critic.prompt.md      # critic prompt with test-aware scoring
```

- `scripts/` - bash entry points; keep them POSIX-friendly and shellcheck clean.
- `references/` - authoritative checklists and fallback docs.
- `templates/` - output templates consumed by `report.sh`.
- `.forge-standard-review/` - per-repo runtime memory (gitignored, never committed).

## Test-Aware Review

When the target repo has tests, the review loop includes them automatically. Detection is non-failing and uses guards for `tests/` `testsuite/` `__tests__/` `spec/` directories, glob patterns `**/*.test.*` `**/*.spec.*` via `find . -maxdepth 4 -name "*.test.*"`, and config files `pytest.ini` `vitest.config.*` `jest.config.*` `pyproject.toml` pytest `package.json` script test and `Makefile` test - all with `if [ -f ... ]` or `grep -q` guards and `|| true` so review never blocks if none found.

- If tests are detected, `scripts/review.sh` collects (a) list of test files (capped at 20, `find ... | head -20`) and (b) quick discovery with 30s timeout: `timeout 30 pytest --collect-only 2>&1 | head -30 || timeout 30 npm test -- --listTests 2>&1 | head -20 || true` - failure is graceful and does not fail the review.
- `TEST_CONTEXT` is set to `Tests detected: yes` plus file list and discovery output, persisted to `.forge-standard-review/test_context.md` and passed to worker/critic prompts.
- Worker and critic include axis 6 (test quality/coverage): missing tests for changed code, brittle mocks, no edge cases, coverage gaps, test deletion to fake green. Prompt section: "If TEST_CONTEXT shows existing tests, review them for coverage gaps, missing edge cases, brittle mocks, and whether changed code lacks tests."
- Checklist `references/checklist.md` has Test Coverage (Axis 6) with items: changed code has tests? edge cases covered? mocks not brittle? no test deletion to fake green? These map to severity medium/high when missing (missing tests for critical code -> high, typo in test -> low).
- Report `scripts/report.sh` maps test findings to severity and ensures fix/prompt suggests test code: e.g. `add test for changed code: tests/test_foo.py covering boundary and failure cases`.

Example state when tests present:

```bash
cat .forge-standard-review/test_context.md
# Tests detected: yes
# Test files:
# tests/test_foo.py
# tests/test_bar.test.ts
# Discovery:
# tests/test_foo.py::test_boundary
```

Example report snippet mentioning tests:

```
## High

- **src/foo.py | high**
  - reason: missing test coverage for changed code - changed src without test update (Fowler Code Smell)
  - fix: add test for changed code: e.g. tests/test_foo.py covering boundary and failure cases
  - prompt: Act as a senior reviewer, fix high test issue at src/foo.py: missing test coverage ... by add test ...
```

When no tests exist (`Tests detected: no`), the loop skips test checks and does not block - review still passes with exit 0.

## MCP Server

Same-repo server at `mcp/src/server.ts` with manifest `mcp/mcp.json`, stdio transport via `@modelcontextprotocol/sdk`. Mirrors `scripts/review.sh` locally; the default review path has no network calls, while opt-in Semgrep may fetch rules.

### Tool list (synced to `mcp/mcp.json` exactly)

`mcp/mcp.json` declares one tool:

```json
{
  "name": "forge_review",
  "description": "Run forge-standard-review review loop (wraps scripts/review.sh). Supports staged, range, and file modes with ranked report.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "mode": { "type": "string", "enum": ["auto", "staged", "range", "file"], "description": "Review mode: staged (git diff --cached), range (commit range), file (single file), auto (staged else BASE...HEAD)" },
      "range": { "type": "string", "description": "Git range for range mode, e.g. HEAD~1..HEAD or main...feature" },
      "file": { "type": "string", "description": "File path for file mode, e.g. path/to/file.ts" },
      "preview": { "type": "boolean", "description": "If true, only preview the diff without running the loop" },
      "workdir": { "type": "string", "description": "Working directory to run review in (defaults to repo root / current cwd)" }
    },
    "required": []
  }
}
```

Table form:

| Field | Type | Description |
|-------|------|-------------|
| `mode` | `"auto" \| "staged" \| "range" \| "file"` | Review mode: staged (git diff --cached), range (commit range), file (single file), auto (staged else BASE...HEAD) |
| `range` | `string` | Git range for range mode, e.g. `HEAD~1..HEAD` or `main...feature` |
| `file` | `string` | File path for file mode, e.g. `path/to/file.ts` |
| `preview` | `boolean` | If true, only preview the diff without running the loop |
| `workdir` | `string` | Working directory to run review in (defaults to repo root / current cwd) |

All paths are quoted and `workdir` is passed as `cwd` to `spawn("bash", [...])` with `path.resolve` and `existsSync` validation. No shell interpolation.

### Wiring

- `mcp.json` at `mcp/mcp.json` with `transport: stdio`, `command: node`, `args: ["mcp/dist/server.js"]`, `entry: mcp/src/server.ts`.
- `mcp/src/server.ts` implements `initialize`, `tools/list`, `tools/call` for `forge_review`.
- Client config at `examples/claude-config.json` with `mcpServers.forge-standard-review.command = node` and quoted `cwd`.
- Runnable demos: `examples/mcp-client.js` (node) and `examples/stdio-smoke.sh` (bash piped JSON-RPC), both support quoted `--workdir` with spaces.
- Inspector: `npx @modelcontextprotocol/inspector node mcp/dist/server.js` then verify `tools/list` shows `forge_review`.

## Conventions

- Keep reviews deterministic: same input diff produces same ordered findings.
- Write findings as actionable items with file:line, severity, and fix hint.
- Prefer knowledge fallback chain over hard-coded rules when repo docs exist.
- No network calls in the default loop; all analysis is local. Opt-in Semgrep may fetch rules.
- Respect `.gitignore` and `.forge-standard-review/` isolation.
