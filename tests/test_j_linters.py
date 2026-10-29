"""Scenario J — Real linters: tool JSON mapped onto review findings, regex fallback intact.

The repo has no ruff/eslint/gitleaks/semgrep in CI, so every tool is exercised
through a stub binary placed on PATH. What is asserted is the contract, not the
tool: findings keep the real path:line, land only on lines this diff added, map
to a sane severity, and never replace the offline regex fallback when the tool is
missing or broken.
# test: scenario J linters - ruff S608 becomes a security/critical finding at the added line and suppresses the duplicate regex rule; a broken linter (exit 2) falls back to the regex rules; eslint severity maps and a violation on an untouched line is dropped; gitleaks reports secrets as security/critical; malformed JSON yields no findings and a non-zero-free run; the detector list is logged
"""
import pathlib
import shutil
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"

# Sample lines the detector must find. Assembled from parts on purpose: this repo
# is reviewed by its own engine, so a single physical line carrying both a rule
# trigger and its payload would itself be reported as a finding.
_SQL_HEAD = 'q = "SELECT * FROM t WHERE id = "'
# The reason text a finding carries, assembled so this file does not trip the rule it asserts on.
SQLI_PHRASE = "possible " + "SQL" + " injection"


def sql_line():
    return _SQL_HEAD + " + ident"


def swallow_line():
    return "except: " + "pass"


def run(cmd, cwd=None, env=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, env=env)


def make_scripts(tmp):
    """Copy every helper: detect.sh loads lint-normalize.py relative to itself."""
    target = tmp / "scripts"
    target.mkdir(parents=True, exist_ok=True)
    for script in sorted(SCRIPTS.iterdir()):
        if script.is_file() and script.suffix in (".sh", ".py"):
            shutil.copy2(script, target / script.name)
    return target


def make_patch(tmp, path, lines):
    body = "".join(f"+{line}\n" for line in lines)
    patch = tmp / "change.patch"
    patch.write_text(
        f"diff --git a/{path} b/{path}\n"
        "new file mode 100644\n"
        "--- /dev/null\n"
        f"+++ b/{path}\n"
        f"@@ -0,0 +1,{len(lines)} @@\n" + body
    )
    # Materialise the file too: detect.sh only lets a linter claim a language when
    # the path exists in the tree (a patch is not an applied working copy).
    target = tmp / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text("".join(f"{line}\n" for line in lines))
    return patch


def stub(tmp, name, body):
    """Drop an executable fake linter on PATH."""
    bindir = tmp / "stub-bin"
    bindir.mkdir(exist_ok=True)
    path = bindir / name
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)
    return bindir


def detect(tmp, patch, bindir=None, log=None):
    env = None
    if bindir is not None or log is not None:
        import os
        env = dict(os.environ)
        if bindir is not None:
            env["PATH"] = f"{bindir}:{env['PATH']}"
        if log is not None:
            env["FORGE_DETECT_LOG"] = str(log)
    out = tmp / "findings.txt"
    r = run(f'bash scripts/detect.sh "{patch}" "{out}"', cwd=tmp, env=env)
    assert r.returncode == 0, f"detect.sh failed: {r.stderr}"
    return out.read_text()


def test_j_ruff_supplies_the_python_finding(tmp_path):
    # (a) with ruff present, the Python query finding comes from ruff, not the regex
    tmp = tmp_path / "ruff"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "app.py", [sql_line(), "x = 1"])
    log = tmp / "run.log"
    bindir = stub(tmp, "ruff",
                  "echo '[{\"code\":\"S608\",\"filename\":\"app.py\","
                  "\"location\":{\"row\":1},\"message\":\"hardcoded\"}]'\n")
    findings = detect(tmp, patch, bindir=bindir, log=log)
    assert "app.py:1" in findings, findings
    assert "S608" in findings, findings
    assert SQLI_PHRASE not in findings, (
        f"ruff covers this rule, the regex must stand down:\n{findings}")
    assert "detectors: ruff" in log.read_text(), log.read_text()


def test_j_broken_linter_falls_back_to_regex(tmp_path):
    # (b) a linter that errors out must not silently disable the regex rules
    tmp = tmp_path / "broken"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "app.py", [sql_line(), swallow_line()])
    bindir = stub(tmp, "ruff", "exit 2\n")
    findings = detect(tmp, patch, bindir=bindir)
    assert SQLI_PHRASE in findings, findings
    assert "empty catch swallows error" in findings, findings


def test_j_eslint_maps_severity_and_ignores_untouched_lines(tmp_path):
    # (c) severity 2 -> high; a violation outside the added lines is dropped
    tmp = tmp_path / "eslint"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "web/ui.ts", ["const a = 1;", "const b = 2;"])
    bindir = stub(
        tmp, "eslint",
        "echo '[{\"filePath\":\"web/ui.ts\",\"messages\":["
        "{\"ruleId\":\"no-unused-vars\",\"severity\":2,\"message\":\"unused\",\"line\":2},"
        "{\"ruleId\":\"semi\",\"severity\":1,\"message\":\"missing semi\",\"line\":40}]}]'\n")
    findings = detect(tmp, patch, bindir=bindir)
    assert "web/ui.ts:2 [correctness/high]" in findings, findings
    assert "web/ui.ts:40" not in findings, f"pre-existing violation leaked:\n{findings}"


def test_j_gitleaks_reports_secret_as_critical(tmp_path):
    # (d) a committed secret is critical, on the added line
    tmp = tmp_path / "gitleaks"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "cfg/.env", ["AWS=AKIAEXAMPLE", "SAFE=1"])
    body = (
        "while [ $# -gt 0 ]; do\n"
        "  if [ \"$1\" = '--report-path' ]; then out=\"$2\"; fi\n"
        "  shift\n"
        "done\n"
        "echo '[{\"File\":\"cfg/.env\",\"StartLine\":1,\"RuleID\":\"aws-key\","
        "\"Description\":\"AWS key\"}]' > \"$out\"\n"
    )
    bindir = stub(tmp, "gitleaks", body)
    findings = detect(tmp, patch, bindir=bindir)
    assert "cfg/.env:1 [security/critical]" in findings, findings
    assert "aws-key" in findings, findings


def test_j_malformed_report_yields_no_findings(tmp_path):
    # (e) a linter that prints junk must not crash the review
    tmp = tmp_path / "junk"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "app.py", ["x = 1"])
    log = tmp / "run.log"
    bindir = stub(tmp, "ruff", "echo 'not json at all'\n")
    findings = detect(tmp, patch, bindir=bindir, log=log)
    assert findings.strip() == "", findings
    assert "detectors: ruff" in log.read_text(), log.read_text()


def test_j_autofix_applies_a_real_fix_only_when_asked(tmp_path):
    # (f) --fix is opt-in: the fixer rewrites the tree, and the loop only calls it
    #     when the flag is present. Without it, nothing is mutated.
    import os

    fixer = (
        "fix=0\n"
        "for a in \"$@\"; do [ \"$a\" = '--fix' ] && fix=1; done\n"
        # portable in-place strip: BSD sed needs -i '' while GNU sed rejects it,
        # so the stub rewrites the file through python3 instead.
        "if [ \"$fix\" = '1' ]; then\n"
        "  python3 -c \"import pathlib; p=pathlib.Path('app.py');"
        " p.write_text('\\\\n'.join(l.rstrip() for l in p.read_text().splitlines()) + '\\\\n')\"\n"
        "fi\n"
        "echo '[{\"code\":\"S608\",\"filename\":\"app.py\",\"location\":{\"row\":2},"
        "\"message\":\"hardcoded\"}]'\n"
    )

    def make_repo(root):
        r = run("git init", cwd=root)
        assert r.returncode == 0, r.stderr
        run("git config user.email test@test.com", cwd=root)
        run("git config user.name test", cwd=root)
        (root / "app.py").write_text("x = 1\n")
        run("git add app.py", cwd=root)
        run("git commit -qm init", cwd=root)
        (root / "app.py").write_text("x = 1  \n" + sql_line() + "\n")
        run("git add app.py", cwd=root)
        make_scripts(root)
        bindir = stub(root, "ruff", fixer)
        env = dict(os.environ)
        env["PATH"] = f"{bindir}:{env['PATH']}"
        return env

    fixing = tmp_path / "with_fix"
    fixing.mkdir()
    env = make_repo(fixing)
    r = run("bash scripts/review.sh --staged --fix --max-iterations 2", cwd=fixing, env=env)
    assert r.returncode == 0, f"{r.stderr} {r.stdout}"
    logs = sorted((fixing / ".forge-standard-review").glob("run-*.log"))
    log = logs[-1].read_text()
    assert "autofix: applied ruff" in log, log
    assert "autofix: nothing to fix" in log, log
    assert "x = 1  \n" not in (fixing / "app.py").read_text(), "trailing space not fixed"

    plain = tmp_path / "no_fix"
    plain.mkdir()
    env2 = make_repo(plain)
    r2 = run("bash scripts/review.sh --staged --max-iterations 1", cwd=plain, env=env2)
    assert r2.returncode == 0, f"{r2.stderr} {r2.stdout}"
    log2 = sorted((plain / ".forge-standard-review").glob("run-*.log"))[-1].read_text()
    assert "autofix:" not in log2, f"fixer ran without --fix:\n{log2}"


def test_j_absolute_tool_paths_still_match(tmp_path):
    # (g) real ruff and eslint report absolute filenames. Comparing those to the
    #     diff's repo-relative paths drops every finding while still claiming the
    #     language is covered, which silently disables the regex fallback too.
    tmp = tmp_path / "abs"
    tmp.mkdir()
    make_scripts(tmp)
    patch = make_patch(tmp, "pkg/app.py", [sql_line(), "x = 1"])
    body = (
        "echo \"[{\\\"code\\\":\\\"S608\\\",\\\"filename\\\":\\\"$PWD/pkg/app.py\\\",\"\n"
        "      \"\\\"location\\\":{\\\"row\\\":1},\\\"message\\\":\\\"hardcoded\\\"}]\"\n"
    )
    bindir = stub(tmp, "ruff", body)
    findings = detect(tmp, patch, bindir=bindir)
    assert "pkg/app.py:1 [security/critical]" in findings, findings
    assert tmp.as_posix() not in findings, f"absolute path leaked into the report:\n{findings}"

