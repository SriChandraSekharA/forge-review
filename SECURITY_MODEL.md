# Threat model: forge-standard-review

## System overview
forge-standard-review is a local, offline code-review tool, distributed as an agent skill (`npx skills add SriChandraSekharA/forge-standard-review`) and as an npm-publishable stdio MCP server (`forge-standard-review-mcp`, also built by `mcp/Dockerfile`). There is no network service, no authentication and no hosted backend. `SECURITY.md` only describes vulnerability disclosure; this document is the security model.

### Components
| Component | Code | Notes |
|---|---|---|
| **review-scripts** | `scripts/review.sh`, `init.sh`, `report.sh`, `critic.sh`, `merge.sh`, `history.sh`, `knowledge.sh`, `templates/`, `references/` | Bash review loop. Reads git diffs or files, writes state to `.forge-standard-review/` in the current working directory. |
| **mcp-server** | `mcp/src/server.ts` (built to `mcp/dist/`), `mcp/mcp.json`, `mcp/Dockerfile`, `examples/` | stdio JSON-RPC server. Tool `forge_review` (`mode`, `range`, `file`, `preview`, `workdir`) spawns `bash scripts/review.sh` with `cwd=workdir`. Exposes resources `report.md` / `review.json` and a `review` prompt. |
| **ci-supply-chain** | `.github/workflows/ci.yml`, `package.json`, `package-lock.json`, `mcp/package*.json`, `SKILL.md` | CI (`permissions: contents: read`, SHA-pinned actions), npm dependencies, skill/npm distribution. |
| **docs-site** | `_config.yml`, `index.md`, `_includes/`, `assets/`, `robots.txt` | Jekyll GitHub Pages site, static, `theme.js` uses localStorage only. |
| **maintainer-tooling** | `.omo/`, `scripts/poll-skills.sh`, `docs/` | Maintainer-run scripts and notes; `poll-skills.sh` is the only code that makes network calls (curl to skills.sh). |
| **tests** | `tests/`, `mcp/tests/`, `fixture_test.js`, `vitest.config.ts` | Test code and fixtures. |

## Trust boundaries and entry points
1. **MCP client → mcp-server** (stdio): tool arguments come from an AI agent that may be prompt-injected by content it read. `range` is forwarded to `review.sh --range` and then to `git diff $range_val` unquoted (word splitting / git option injection, e.g. `--output=`); `workdir` is any path the process can reach (`path.resolve`, only an existence check); `file` is read and echoed into the review output. Resource reads resolve under the server's repo root.
2. **Reviewed repository content → review-scripts**: diff text, file names, branch names and repository-local git config of the code under review are untrusted (a hostile PR). `.forge-standard-review/` state files (`state.json`, `.pid`, `learning.md`) in the reviewed repo are also attacker-controllable if committed.
3. **Developer CLI → review-scripts**: the local developer runs the scripts directly; trusted.
4. **Supply chain**: npm dependencies (`@modelcontextprotocol/sdk`, vitest, typescript), the published npm package and skill contents, CI actions, Docker base image `node:20-alpine`.

## Assets
All equally important:
- The developer's machine: no unintended command execution, file writes or deletions outside `.forge-standard-review/`.
- Source code and secrets in the repositories being reviewed (confidentiality, e.g. via arbitrary file read through `file`/`workdir`/resources).
- Integrity of review results (findings cannot be suppressed, faked or score-gamed by the reviewed content).
- Integrity of the published package/skill and CI.

## Attacker profiles (all in scope)
- **Malicious reviewed content**: author of a hostile PR, diff or crafted file name the tool reviews.
- **Prompt-injected AI agent / MCP client**: passes crafted `range`, `file`, `workdir` arguments.
- **Supply-chain attacker**: tampered npm dependency, package or skill install.
- **Local developer**: trusted, but findings that only need local developer access are still in scope.

## Existing controls
- MCP server spawns `bash` with an argv array (no shell string), `stdio` stdin ignored.
- Scripts use `set -euo pipefail`; review loop documented as local-only, no network.
- CI: read-only `GITHUB_TOKEN`, actions pinned to SHAs, release/archive steps manual.
- `review.sh` proposes fixes but does not apply patches automatically.

## Out of scope / accepted risk
Nothing: everything in the repository is in scope.

## Infrastructure
No infrastructure repository: it is a local CLI/MCP tool shipped via npm and skills. The only deployment artifact is `mcp/Dockerfile`.

## Open questions
- Is the MCP server intended to be usable only against the repo it ships in, or against arbitrary `workdir`s? (Affects how much `workdir` freedom is intended.)
- Is the npm package `forge-standard-review-mcp` actually published, and from where (manual or CI)?
