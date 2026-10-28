"""Scenario E — Learning loop: feedback memory + iteration caps + tests hook (Greptile-inspired).
learn.sh feedback CLI (JSONL memory, dedupe, --list) + review.sh dismiss/floor filters,
--max-iterations/--max-fixes, --tests hook. Real bash, real git, no mocks, no network.
# test: scenario E learning - learn.sh writes single-line JSONL to explicit target + dedupes + lists; review.sh suppresses dismissed findings, floors severities, honors --max-iterations 1, injects [test/high] synthetic finding on failing --tests cmd only
"""
import json
import subprocess
import pathlib
import shutil

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"


def run(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


def make_repo(tmp):
    """git repo + only the scripts under test copied in (review.sh invokes critic.sh script-relatively)."""
    r = run("git init", cwd=tmp)
    assert r.returncode == 0, r.stderr
    run("git config user.email test@test.com", cwd=tmp)
    run("git config user.name test", cwd=tmp)
    (tmp / "scripts").mkdir()
    # copy every script: review.sh orchestrates detect.sh + critic.sh script-relatively
    for script in sorted(SCRIPTS.glob("*.sh")):
        shutil.copy2(script, tmp / "scripts" / script.name)
    return tmp


def stage_diff(tmp):
    """Staged diff triggering two worker findings: console.log (low) + TODO (medium)."""
    (tmp / "app.js").write_text(
        "function f() {\n  console.log('debug');\n  // TODO: handle error\n  return 1;\n}\n"
    )
    r = run("git add app.js", cwd=tmp)
    assert r.returncode == 0, r.stderr


def learning_md(tmp):
    return (tmp / ".forge-standard-review" / "learning.md").read_text()


def run_log_text(tmp):
    logs = sorted((tmp / ".forge-standard-review").glob("run-*.log"))
    assert logs, "no run log produced"
    return logs[-1].read_text()


def test_e_dismiss_suppresses_matching_only(tmp_path):
    # (a) dismiss rule (path glob + reason regex) suppresses matching finding; non-matching stays
    tmp = tmp_path / "dismiss"
    tmp.mkdir()
    make_repo(tmp)
    stage_diff(tmp)
    r = run("bash scripts/learn.sh --dismiss --file 'app.js' --rule 'console\\.log' --reason 'noise'", cwd=tmp)
    assert r.returncode == 0, r.stderr
    assert "learned:" in r.stdout, r.stdout
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    learning = learning_md(tmp)
    assert "console.log leftover" not in learning, learning
    assert "TODO/FIXME left" in learning, learning  # non-matching finding survives
    assert "learning: 1 suppressed (0 below floor)" in r.stdout, r.stdout
    assert "learning: 1 suppressed (0 below floor)" in run_log_text(tmp)
    print(f"ARTIFACT learning.md (dismiss):\n{learning}")


def test_e_floor_drops_below_floor_with_count(tmp_path):
    # (b) severity floor medium drops the low console.log finding, keeps medium TODO; count in output
    tmp = tmp_path / "floor"
    tmp.mkdir()
    make_repo(tmp)
    stage_diff(tmp)
    r = run("bash scripts/learn.sh --floor --severity medium --reason 'keep bar'", cwd=tmp)
    assert r.returncode == 0, r.stderr
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    learning = learning_md(tmp)
    assert "console.log leftover" not in learning, learning  # low < medium floor -> dropped
    assert "TODO/FIXME left" in learning, learning           # medium == floor -> kept
    assert "learning: 1 suppressed (1 below floor)" in r.stdout, r.stdout
    assert "learning: 1 suppressed (1 below floor)" in run_log_text(tmp)
    print(f"ARTIFACT learning.md (floor):\n{learning}")


def test_e_max_iterations_one(tmp_path):
    # (c) --max-iterations 1 -> exactly 1 iteration in run log even when gate is NOT met
    tmp = tmp_path / "iters"
    tmp.mkdir()
    make_repo(tmp)
    # findings include an empty catch (high) -> severity-cap score 5 < 8 (gate fails), so the stop is the cap, not the gate
    (tmp / "app.js").write_text(
        "function f() {\n  console.log('debug');\n  // TODO: handle error\n"
        "  try { g(); } catch (e) {}\n  return 1;\n}\n"
    )
    r = run("git add app.js", cwd=tmp)
    assert r.returncode == 0, r.stderr
    r = run("bash scripts/review.sh --staged --max-iterations 1", cwd=tmp)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    log = run_log_text(tmp)
    iters = [l for l in log.splitlines() if l.startswith("=== Iteration ")]
    assert len(iters) == 1, f"expected exactly 1 iteration, got {iters}"
    assert iters[0] == "=== Iteration 1 ==="
    assert "=== Iteration 2 ===" not in log
    assert "Max iterations (1) reached" in log, log  # proves gate did not pass first
    print(f"ARTIFACT run log (max-iterations 1):\n{log}")


def test_e_tests_hook_failing_and_passing(tmp_path):
    # (d) failing --tests cmd -> one synthetic [test/high] finding + output tail; passing -> none
    fail = tmp_path / "fail"
    fail.mkdir()
    make_repo(fail)
    stage_diff(fail)
    r = run("bash scripts/review.sh --staged --max-iterations 1 --tests 'echo boom-output; exit 7'", cwd=fail)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    learning = learning_md(fail)
    assert "[test/high] test command failed (exit 7): echo boom-output; exit 7" in learning, learning
    assert "test-output: boom-output" in learning, learning  # output-tail line captured
    log = run_log_text(fail)
    assert "tests hook: command failed (exit 7)" in log, log
    print(f"ARTIFACT learning.md (failing tests):\n{learning}")

    ok = tmp_path / "pass"
    ok.mkdir()
    make_repo(ok)
    stage_diff(ok)
    r = run("bash scripts/review.sh --staged --max-iterations 1 --tests 'true'", cwd=ok)
    assert r.returncode == 0, f"review failed: {r.stderr} {r.stdout}"
    learning = learning_md(ok)
    assert "[test/high]" not in learning, learning
    assert "tests hook: command passed (exit 0)" in run_log_text(ok)
    print(f"ARTIFACT learning.md (passing tests): no [test/high] finding")


def test_e_learn_dedupe_and_list(tmp_path):
    # (e) 2nd identical dismiss = no-op ("already learned", exit 0); --list shows entries
    tmp = tmp_path / "learn"
    tmp.mkdir()
    (tmp / "scripts").mkdir()
    shutil.copy2(SCRIPTS / "learn.sh", tmp / "scripts" / "learn.sh")
    target = tmp / "target-repo"
    target.mkdir()
    cmd = ("bash scripts/learn.sh --dismiss --file 'src/*.py' --rule 'console\\.log'"
           " --reason 'noise' target-repo")
    r1 = run(cmd, cwd=tmp)
    assert r1.returncode == 0, r1.stderr
    assert "learned:" in r1.stdout, r1.stdout
    r2 = run(cmd, cwd=tmp)
    assert r2.returncode == 0, r2.stderr
    assert "already learned" in r2.stdout, r2.stdout
    assert "learned:" not in r2.stdout, r2.stdout  # no second write
    # invalid severity / missing args -> non-zero exit
    r3 = run("bash scripts/learn.sh --floor --severity bogus --reason x target-repo", cwd=tmp)
    assert r3.returncode != 0, r3.stdout
    r4 = run("bash scripts/learn.sh --dismiss --file 'a.py' target-repo", cwd=tmp)
    assert r4.returncode != 0, r4.stdout
    # --list reads the SAME resolved file and shows the entry (pretty-printed per entry)
    r5 = run("bash scripts/learn.sh --list target-repo", cwd=tmp)
    assert r5.returncode == 0, r5.stderr
    assert "(no feedback learned)" not in r5.stdout, r5.stdout
    assert '"action": "dismiss"' in r5.stdout, r5.stdout
    assert "src/*.py" in r5.stdout, r5.stdout
    print(f"ARTIFACT learn --list:\n{r5.stdout}")


def test_e_learn_writes_explicit_target(tmp_path):
    # (f) regression: file exists at <target>/.forge-standard-review/feedback.jsonl after write;
    # JSONL contract holds (every line is a valid single-line JSON object)
    tmp = tmp_path / "target-write"
    tmp.mkdir()
    (tmp / "scripts").mkdir()
    shutil.copy2(SCRIPTS / "learn.sh", tmp / "scripts" / "learn.sh")
    target = tmp / "some-target"
    target.mkdir()
    r = run(("bash scripts/learn.sh --dismiss --file 'src/*.py' --rule 'console\\.log'"
             " --reason 'noise' some-target"), cwd=tmp)
    assert r.returncode == 0, r.stderr
    fb = target / ".forge-standard-review" / "feedback.jsonl"
    assert fb.exists(), f"feedback.jsonl missing at {fb}"
    lines = [l for l in fb.read_text().splitlines() if l.strip()]
    assert len(lines) == 1, lines
    entry = json.loads(lines[0])  # single-line JSONL, not pretty-printed multi-line
    assert entry["action"] == "dismiss", entry
    assert entry["path"] == "src/*.py", entry
    assert entry["rule"] == "console\\.log", entry
    assert "ts" in entry and entry["ts"], entry
    # default target (no positional arg) resolves script-relative to the copied repo root
    r2 = run("bash scripts/learn.sh --floor --severity low --reason 'flaky'", cwd=tmp)
    assert r2.returncode == 0, r2.stderr
    default_fb = tmp / ".forge-standard-review" / "feedback.jsonl"
    assert default_fb.exists(), f"default-resolution feedback.jsonl missing at {default_fb}"
    assert len(default_fb.read_text().splitlines()) == 1
    print(f"ARTIFACT feedback.jsonl (explicit target):\n{fb.read_text()}")
