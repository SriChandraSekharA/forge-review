"""Scenario I — Honest review signal: severity-cap score + real path:line + convergence stop.
The score must not rise just because the loop ran again, findings must point at source
lines (not diff-text offsets), and the loop must stop when nothing changed.
# test: scenario I honest signal - critic score is a pure function of findings (critical caps 3, high 5, medium 7, low 8-10, identical across iterations); review.sh reports <file>:<line> resolved from hunk headers; clean diff scores 10 and passes at iteration 1; unchanged findings stop the loop early
"""
import pathlib
import shutil
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"


def run(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


# Sample lines the detector must find. They are assembled from parts on purpose:
# this repo is reviewed by its own engine, and a single physical line carrying both
# a rule trigger and its payload would be reported as a finding in this test file.
_SQL_HEAD = 'const query = "SELECT * FROM users WHERE id = "'
_SQL_TAIL = " + input;"


def sql_line():
    return _SQL_HEAD + _SQL_TAIL


def empty_catch_line():
    return "try { doRisk(); } catch (e) " + "{}"


def make_repo(tmp):
    r = run("git init", cwd=tmp)
    assert r.returncode == 0, r.stderr
    run("git config user.email test@test.com", cwd=tmp)
    run("git config user.name test", cwd=tmp)
    (tmp / "scripts").mkdir()
    # review.sh orchestrates detect.sh + critic.sh script-relatively
    for script in sorted(SCRIPTS.glob("*.sh")):
        shutil.copy2(script, tmp / "scripts" / script.name)
    return tmp


def learning_md(tmp):
    return (tmp / ".forge-standard-review" / "learning.md").read_text()


def run_log_text(tmp):
    logs = sorted((tmp / ".forge-standard-review").glob("run-*.log"))
    assert logs, "no run log produced"
    return logs[-1].read_text()


def test_i_score_is_stable_across_iterations(tmp_path):
    # (a) the same findings must score the same on iteration 1 and iteration 4
    tmp = tmp_path / "stable"
    tmp.mkdir()
    findings = tmp / "findings.txt"
    # reason text assembled so this fixture does not match the SQLi rule itself
    sqli_reason = "possible " + "SQL" + " injection (CWE-89)"
    findings.write_text(
        f"L: app.js:2 [security/critical] {sqli_reason} -> fix hint: use parameterized query\n"
        "L: app.js:3 [correctness/high] empty catch swallows error -> fix hint: handle typed error or rethrow\n"
    )
    scores = []
    for iteration in (1, 2, 4, 8):
        r = run(f'bash "{SCRIPTS / "critic.sh"}" "{findings}" {iteration}')
        assert r.returncode == 0, r.stderr
        line = [l for l in r.stdout.splitlines() if l.startswith("score:")][0]
        scores.append(int(line.split(":")[1].strip()))
    assert len(set(scores)) == 1, f"score changed with iteration: {scores}"
    assert scores[0] == 3, f"critical findings must cap the score at 3, got {scores[0]}"


def test_i_severity_caps(tmp_path):
    # (b) each severity caps the score; only low/nitpick can reach the gate
    tmp = tmp_path / "caps"
    tmp.mkdir()
    cases = {
        "critical": ("L: a.js:1 [security/critical] x -> y\n", 3),
        "high": ("L: a.js:1 [correctness/high] x -> y\n", 5),
        "medium": ("L: a.js:1 [readability/medium] x -> y\n", 7),
        "low": ("L: a.js:1 [readability/low] x -> y\n", 9),
    }
    for sev, (body, expected) in cases.items():
        f = tmp / f"{sev}.txt"
        f.write_text(body)
        r = run(f'bash "{SCRIPTS / "critic.sh"}" "{f}" 1')
        score = int([l for l in r.stdout.splitlines() if l.startswith("score:")][0].split(":")[1])
        assert score == expected, f"{sev}: expected {expected}, got {score}"
    clean = tmp / "clean.txt"
    clean.write_text("")
    r = run(f'bash "{SCRIPTS / "critic.sh"}" "{clean}" 3')
    assert "score: 10" in r.stdout, r.stdout


def test_i_findings_point_at_real_source_lines(tmp_path):
    # (c) a finding on the 2nd line of the file reports app.js:2, never diff:<offset>
    tmp = tmp_path / "lines"
    tmp.mkdir()
    make_repo(tmp)
    (tmp / "app.js").write_text(
        "const input = req.query.id;\n" + sql_line() + "\n" + empty_catch_line() + "\n"
    )
    r = run("git add app.js", cwd=tmp)
    assert r.returncode == 0, r.stderr
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    learning = learning_md(tmp)
    assert "app.js:2" in learning, f"expected real source line app.js:2 in:\n{learning}"
    assert "app.js:3" in learning, f"expected real source line app.js:3 in:\n{learning}"
    assert "diff:" not in learning, f"diff-text offset leaked into findings:\n{learning}"
    # one critical finding caps the run at 3, so the gate must not pass
    assert "score: 3" in r.stdout, r.stdout
    assert "Gate passed" not in r.stdout, "gate must not pass while a critical finding is open"


def test_i_clean_diff_passes_and_converges(tmp_path):
    # (d) clean diff scores 10 at iteration 1; an unchanged dirty set stops the loop early
    clean = tmp_path / "clean"
    clean.mkdir()
    make_repo(clean)
    (clean / "app.js").write_text("const total = items.reduce((a, b) => a + b, 0);\n")
    run("git add app.js", cwd=clean)
    r = run("bash scripts/review.sh --staged", cwd=clean)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    assert "Gate passed at iteration 1 with score 10" in r.stdout, r.stdout

    dirty = tmp_path / "dirty"
    dirty.mkdir()
    make_repo(dirty)
    (dirty / "app.js").write_text(empty_catch_line() + "\n")
    run("git add app.js", cwd=dirty)
    r2 = run("bash scripts/review.sh --staged --max-iterations 8", cwd=dirty)
    assert r2.returncode == 0, f"review failed: {r2.stderr} {r2.stdout}"
    log = run_log_text(dirty)
    assert "converged: findings unchanged" in log, log
    assert "=== Iteration 3 ===" not in log, f"loop did not stop at convergence:\n{log}"
