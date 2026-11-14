---
layout: home
title: Forge Standard Review
description: Quota-free iterative code review with continuous loop — idempotent per-repo memory
image: https://srichandrasekhara.github.io/forge-review/assets/badge.svg
---

<div class="forge-hero">
  <!-- The minima theme ships no stylesheet link in <head>, so the page loads the
       site stylesheet here. Drop this line if custom-head.html ever links
       /assets/css/style.css itself. -->
  <link rel="stylesheet" href="https://srichandrasekhara.github.io/forge-review/assets/css/style.css">
  <p class="forge-eyebrow">No API keys · no quota · nothing leaves the machine</p>
  <p class="forge-lede">Forge Standard Review reads your diff, ranks what it finds from critical to nitpick, and keeps going until the findings stop changing. It is a handful of shell scripts in your repository — the loop costs nothing per run, because there is nothing to call.</p>
  <p class="forge-hero__actions">
    <a class="forge-btn forge-btn--primary" href="#install">Install it</a>
    <a class="forge-btn forge-btn--ghost" href="https://github.com/SriChandraSekharA/forge-review">Read the source</a>
  </p>
  <p class="forge-hero__meta">git · hg · or no VCS at all &nbsp;/&nbsp; bash 4+ or zsh &nbsp;/&nbsp; jq optional</p>
</div>

## What it does

One pass over a diff is rarely the answer. Code has to be read, fixed, and read again
until the same findings stop coming back. Forge Standard Review is that loop, wired to
tools you already have.

<div class="forge-grid">
  <article class="forge-card">
    <h3>Findings point at real lines</h3>
    <p>Every finding carries the <code>path:line</code> from the diff hunk header — <code>src/foo.py:87</code>, not an offset into patch text.</p>
  </article>
  <article class="forge-card">
    <h3>The loop converges</h3>
    <p>It stops when the finding set stops changing. <code>--max-iterations</code> is there as a bound, not as the exit.</p>
  </article>
  <article class="forge-card">
    <h3>The score follows the findings</h3>
    <p>Critical caps the score at 3, high at 5, medium at 7. Only low and nitpick reach the 8/10 gate, so a longer loop cannot inflate it.</p>
  </article>
  <article class="forge-card">
    <h3>Linters first, rules after</h3>
    <p>ruff, eslint and gitleaks judge the lines this diff added when they are installed; the regex rules cover the machines where they are not.</p>
  </article>
  <article class="forge-card">
    <h3>It remembers your repo</h3>
    <p>Dismissed finding classes, severity floors and plain-English rules are recorded once and applied on every later run.</p>
  </article>
  <article class="forge-card">
    <h3>Nothing leaves the machine</h3>
    <p>No keys, no network calls, no uploads. The analysis is local shell and the linters already on your <code>PATH</code>.</p>
  </article>
</div>

Two more hooks into the loop: `--tests CMD` runs your test command once per iteration and
turns a failure into a high-severity finding, and `./scripts/impact.sh` traces importers
and callers beyond the diff into an impact section of the report.

## Five review axes

Each finding is filed under one of five axes. The checklist behind them lives in
`references/checklist.md` and is copied into the repo on first run.

<ol class="forge-axes">
  <li>
    <span class="forge-num">01</span>
    <div>
      <h3>Correctness</h3>
      <p>Happy and edge paths, null and empty input, typed errors instead of swallowed ones, invariants held across the call path.</p>
    </div>
  </li>
  <li>
    <span class="forge-num">02</span>
    <div>
      <h3>Security</h3>
      <p>OWASP Top 10 ground: input validated, output encoded, authorization checked on every path, no secrets in code or logs.</p>
    </div>
  </li>
  <li>
    <span class="forge-num">03</span>
    <div>
      <h3>Architecture</h3>
      <p>Modules small and single-purpose, dependencies pointing one way, SOLID layers kept, dead code removed.</p>
    </div>
  </li>
  <li>
    <span class="forge-num">04</span>
    <div>
      <h3>Readability</h3>
      <p>Names that reveal intent, comments that explain why rather than what, units that do one thing.</p>
    </div>
  </li>
  <li>
    <span class="forge-num">05</span>
    <div>
      <h3>Performance</h3>
      <p>Algorithm cost stated, no accidental O(n²) on a hot path, batched I/O, pagination where a set can grow.</p>
    </div>
  </li>
</ol>

A sixth check switches on when the repo already has tests: missing tests for changed code,
boundary gaps, brittle mocks, or a deleted test hiding a failure. When no tests are found,
that check stays quiet and the review still passes.

## Install

### With the skills CLI

```bash
npx --yes skills add SriChandraSekharA/forge-review -g -y
```

`-g` installs for every project; drop it to install into the current one only. To see what
the CLI resolves before it installs anything, ask it to list:

```bash
npx --yes skills add SriChandraSekharA/forge-review -l
```

### From a clone

```bash
git clone https://github.com/SriChandraSekharA/forge-review.git
```

### What it needs

`git` for the staged and range modes, `bash` 4+ (or `zsh`), and `jq` if you want JSON
reports shaped — without `jq`, reports fall back to plain text tables.

```bash
git --version
bash --version
jq --version   # optional
```

## Quick start

Run these from the skill root, or from an installed copy inside your repo:

```bash
./scripts/init.sh
./scripts/review.sh --staged
./scripts/review.sh --range HEAD~1..HEAD
./scripts/review.sh --file path/to/file.ts
./scripts/report.sh --format markdown --output review.md
```

`--staged` reads `git diff --cached`, `--range` takes a commit range or a branch diff,
`--file` reviews one file whatever the VCS state is, and `--diff-file patch` reviews a
patch already on disk without applying it.

### The loop on one commit

<figure class="forge-demo">
  <img src="https://srichandrasekhara.github.io/forge-review/assets/demo.gif" width="900" height="620" loading="lazy" alt="Terminal recording of review.sh scoring one commit 3 out of 10 with two findings, converging after the second iteration, followed by report.sh ranking the findings.">
  <figcaption>Captured from a real run against a throwaway repo with one commit and two defects.</figcaption>
</figure>

```
Iteration 1: score: 3 (2 findings)
Iteration 2: score: 3 (2 findings)
converged: findings unchanged since iteration 1 - stopping
score: 3
```

The second pass found exactly what the first one did, so the score held and the loop
stopped. The report that follows ranks `db.py:5 | critical` above `db.py:8 | high` and
names the file and line each time.

## How the memory loop works

The first run creates a memory folder at the repo root and adds it to `.gitignore`. Every
run after that reuses the folder, merges what changed, and leaves what you wrote alone.

1. **Create.** `init.sh` writes the baseline config, a snapshot of the checklist, and empty
   learning files. Run it again and it validates the folder instead of recreating it.
2. **Review.** `review.sh` reads the diff, runs the detectors, scores the findings, and
   iterates until the finding set converges.
3. **Learn.** `learn.sh` records a dismissal, a severity floor, or a plain-English rule. The
   next run applies them and prints `learning: N suppressed (M below floor)`.
4. **Trace.** `impact.sh` follows imports and callers beyond the diff, and `report.sh` puts
   the result in its own section at the top of the report.
5. **Report.** `report.sh` writes the ranked report — critical, high, medium, low, nitpick —
   with a fix and a prompt for each finding.

```bash
./scripts/learn.sh --dismiss --file "dist/**" --rule "minified artifact" --reason "generated code, not hand-edited"
./scripts/learn.sh --floor --severity medium --reason "release gate: block on medium+ only"
./scripts/learn.sh --rule "prefer early returns over nested conditionals"
```

Inside the folder:

<ul class="forge-files">
  <li><code>state.json</code><span>manifest and the last review time</span></li>
  <li><code>history.md</code><span>history snapshot from the last run</span></li>
  <li><code>learning.md</code><span>one score line per iteration, append-only</span></li>
  <li><code>feedback.jsonl</code><span>dismissals and severity floors</span></li>
  <li><code>rules.md</code><span>plain-English team rules</span></li>
  <li><code>report.md</code><span>the ranked report as written</span></li>
</ul>

<div class="forge-closing">
  <h2 class="forge-closing__title">Read the loop before you trust it</h2>
  <p class="forge-closing__body">The scripts are shell, the checklist is markdown, and the memory is a folder in your own repo. Nothing about the review is hidden behind a service.</p>
  <p class="forge-hero__actions">
    <a class="forge-btn forge-btn--primary" href="https://github.com/SriChandraSekharA/forge-review">Open the repository</a>
    <a class="forge-btn forge-btn--ghost" href="https://github.com/SriChandraSekharA/forge-review/blob/main/references/checklist.md">Read the checklist</a>
  </p>
  <p class="forge-closing__links">
    <a href="https://github.com/SriChandraSekharA/forge-review/blob/main/docs/MCP.md">MCP server</a>
    <a href="https://github.com/SriChandraSekharA/forge-review/blob/main/SECURITY_MODEL.md">Security model</a>
    <a href="https://github.com/SriChandraSekharA/forge-review/blob/main/LICENSE">MIT license</a>
  </p>
</div>
