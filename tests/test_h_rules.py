"""Scenario H — Team rules: plain-English custom rules enforced on every review (Greptile-inspired).
learn.sh --rule/--rules + init.sh/merge.sh rules.md preservation + review.sh injection.
Real bash, real git, no mocks, no network.
# test: scenario H rules - learn.sh --rule appends + dedupes + --rules prints; review.sh injects '# review-rule:' markers and reports 'rules: N active'; rules survive re-init + merge; missing/empty rules file never fails a review
"""
import pathlib
import shutil
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"


def run(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


def make_review_repo(tmp):
    """git repo + scripts under test copied in (review.sh invokes critic.sh script-relatively)."""
    r = run("git init", cwd=tmp)
    assert r.returncode == 0, r.stderr
    run("git config user.email test@test.com", cwd=tmp)
    run("git config user.name test", cwd=tmp)
    (tmp / "scripts").mkdir()
    for name in ("review.sh", "critic.sh", "learn.sh"):
        shutil.copy2(SCRIPTS / name, tmp / "scripts" / name)
    return tmp


def stage_diff(tmp):
    """Staged diff triggering one worker finding (console.log, low)."""
    (tmp / "app.js").write_text("function f() {\n  console.log('debug');\n  return 1;\n}\n")
    r = run("git add app.js", cwd=tmp)
    assert r.returncode == 0, r.stderr


def run_log_text(tmp):
    logs = sorted((tmp / ".forge-standard-review").glob("run-*.log"))
    assert logs, "no run log produced"
    return logs[-1].read_text()


def test_h_learn_rule_appends_dedupes_and_rules_prints(tmp_path):
    # (a) --rule appends '- <text>' to rules.md (header created if missing);
    # 2nd identical rule = no-op "rule already learned, skipping" exit 0
    tmp = tmp_path / "learn"
    tmp.mkdir()
    (tmp / "scripts").mkdir()
    shutil.copy2(SCRIPTS / "learn.sh", tmp / "scripts" / "learn.sh")
    target = tmp / "team-repo"
    target.mkdir()
    rule = "Validate all user input at the boundary before use."
    r1 = run(f'bash scripts/learn.sh --rule "{rule}" team-repo', cwd=tmp)
    assert r1.returncode == 0, r1.stderr
    assert "rule learned:" in r1.stdout, r1.stdout
    rules_md = target / ".forge-standard-review" / "rules.md"
    assert rules_md.exists(), f"rules.md not created at {rules_md}"
    text = rules_md.read_text()
    assert "Team review rules" in text, f"header template missing on create: {text}"
    assert text.count(f"- {rule}") == 1, text
    r2 = run(f'bash scripts/learn.sh --rule "{rule}" team-repo', cwd=tmp)
    assert r2.returncode == 0, r2.stderr
    assert "rule already learned, skipping" in r2.stdout, r2.stdout
    assert "rule learned:" not in r2.stdout, r2.stdout  # no second write
    assert rules_md.read_text().count(f"- {rule}") == 1, "duplicate appended"
    # --rules prints the active lines (comments/blanks stripped)
    r3 = run("bash scripts/learn.sh --rules team-repo", cwd=tmp)
    assert r3.returncode == 0, r3.stderr
    assert f"- {rule}" in r3.stdout, r3.stdout
    assert "#" not in r3.stdout, r3.stdout  # header comments not printed
    # missing rules file -> "(no custom rules)"
    (tmp / "empty-repo").mkdir()
    r4 = run("bash scripts/learn.sh --rules empty-repo", cwd=tmp)
    assert r4.returncode == 0, r4.stderr
    assert "(no custom rules)" in r4.stdout, r4.stdout
    print(f"ARTIFACT rules.md:\n{rules_md.read_text()}\nARTIFACT --rules:\n{r3.stdout}")


def test_h_review_injects_rules_and_reports_count(tmp_path):
    # (b) 2 rules (plus ignored comments/blank lines) -> 'rules: 2 active' in stdout +
    # run log; both rule texts appear as '# review-rule:' markers in the run log
    tmp = tmp_path / "review"
    tmp.mkdir()
    make_review_repo(tmp)
    stage_diff(tmp)
    fsdir = tmp / ".forge-standard-review"
    fsdir.mkdir()
    rule1 = "Always handle empty collections explicitly."
    rule2 = "Every public function carries a why-comment."
    (fsdir / "rules.md").write_text(
        "# Team review rules - plain-English rules enforced on every review\n"
        "# comment lines are ignored\n"
        f"- {rule1}\n"
        f"- {rule2}\n"
        "\n"
    )
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    assert "rules: 2 active" in r.stdout, r.stdout
    log = run_log_text(tmp)
    assert "rules: 2 active" in log, log
    assert f"# review-rule: - {rule1}" in log, log
    assert f"# review-rule: - {rule2}" in log, log
    assert "# review-rule: # " not in log, "comment lines must not be injected as rules"
    print(f"ARTIFACT run log (rules):\n{log}")


def test_h_rules_survive_reinit_and_merge(tmp_path):
    # (c) hand-written rule lines survive re-init + merge (exact-line dedupe, order kept)
    install = tmp_path / "skill-copy"
    install.mkdir()
    shutil.copytree(SCRIPTS, install / "scripts")
    shutil.copytree(REPO_ROOT / "references", install / "references")
    work = tmp_path / "team-project"
    work.mkdir()
    init_sh = install / "scripts" / "init.sh"
    merge_sh = install / "scripts" / "merge.sh"
    r = run(f'bash "{init_sh}"', cwd=work)
    assert r.returncode == 0, f"init failed: {r.stderr} {r.stdout}"
    rules_md = work / ".forge-standard-review" / "rules.md"
    assert rules_md.exists(), "rules.md not created by init.sh"
    custom1 = "- No secrets committed; use env vars."
    custom2 = "- Every migration is reversible."
    with open(rules_md, "a") as f:
        f.write(custom1 + "\n" + custom2 + "\n")
    r2 = run(f'bash "{init_sh}"', cwd=work)
    assert r2.returncode == 0, f"re-init failed: {r2.stderr} {r2.stdout}"
    r3 = run(f'bash "{merge_sh}"', cwd=work)
    assert r3.returncode == 0, f"merge failed: {r3.stderr} {r3.stdout}"
    merged = rules_md.read_text().splitlines()
    for line in (custom1, custom2):
        assert merged.count(line) == 1, f"rule lost or duplicated after re-init: {merged}"
    # foreign rules merge: overlap deduped, new rule appended, order preserved.
    # $2 = file or dir holding rules.md at its root (like a foreign .forge-standard-review/)
    foreign_mem = tmp_path / "other-team" / ".forge-standard-review"
    foreign_mem.mkdir(parents=True)
    custom3 = "- Prefer stdlib over new dependencies."
    (foreign_mem / "rules.md").write_text(f"{custom1}\n{custom3}\n")
    mem = work / ".forge-standard-review"
    r4 = run(f'bash "{merge_sh}" "{mem}" "{foreign_mem}"', cwd=work)
    assert r4.returncode == 0, f"foreign merge failed: {r4.stderr} {r4.stdout}"
    merged = rules_md.read_text().splitlines()
    assert merged.count(custom1) == 1, f"foreign duplicate not deduped: {merged}"
    assert merged.count(custom3) == 1, f"foreign new rule not appended: {merged}"
    assert merged.index(custom1) < merged.index(custom2) < merged.index(custom3), \
        f"order not preserved: {merged}"
    print(f"ARTIFACT rules.md after re-init+merge:\n{rules_md.read_text()}")


def test_h_review_missing_rules_file_never_fails(tmp_path):
    # (d) no rules.md -> review completes, exit 0, 'rules: 0 active' reported;
    # comments-only rules file -> same behavior
    tmp = tmp_path / "norules"
    tmp.mkdir()
    make_review_repo(tmp)
    stage_diff(tmp)
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    assert "rules: 0 active" in r.stdout, r.stdout
    assert "rules: 0 active" in run_log_text(tmp), run_log_text(tmp)
    # comments-only file: same count, still no failure
    for old in (tmp / ".forge-standard-review").glob("run-*.log"):
        old.unlink()
    fsdir = tmp / ".forge-standard-review"
    (fsdir / "rules.md").write_text("# only a comment\n\n")
    r2 = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r2.returncode == 0, f"review failed: {r2.stderr} {r2.stdout}"
    assert "rules: 0 active" in r2.stdout, r2.stdout
    print(f"ARTIFACT run log (no rules):\n{run_log_text(tmp)}")
