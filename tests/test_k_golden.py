"""Scenario K — Golden diffs: the same patch always produces the same verdict.

Each fixture is a real unified diff plus the verdict it must earn, so a scoring or
detection change that would silently re-grade a known diff fails here instead of
being noticed by a human reading a report.

The fixtures under tests/fixtures/*/sample/ deliberately contain vulnerable-looking
code (that is what they test). This repo reviews itself, so those triggers are
expected to appear when the fixtures themselves are added to a review; they are
dismissed for that path only, never for source.

# test: scenario K golden - review.sh --diff-file reproduces the recorded score, severity and path:line for five known patches (critical 3, high 5, medium 7, low 9, clean 10); an unreadable patch is rejected with exit 2
"""
import json
import pathlib
import shutil
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = REPO_ROOT / "scripts"
FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"


def run(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


def make_scripts(tmp):
    """A review sandbox: only the scripts, no git, no repo config."""
    (tmp / "scripts").mkdir(parents=True)
    for script in sorted(SCRIPTS.glob("*.sh")):
        shutil.copy2(script, tmp / "scripts" / script.name)
    for helper in sorted(SCRIPTS.glob("*.py")):
        shutil.copy2(helper, tmp / "scripts" / helper.name)
    return tmp


def finding_lines(tmp):
    learning = tmp / ".forge-standard-review" / "learning.md"
    assert learning.exists(), "review produced no learning.md"
    return [line for line in learning.read_text().splitlines() if line.startswith("L: ")]


def fixture_dirs():
    return sorted(p for p in FIXTURES.iterdir() if p.is_dir() and (p / "diff.patch").is_file())


def test_k_golden_verdicts(tmp_path):
    cases = fixture_dirs()
    assert len(cases) >= 5, f"expected the five golden cases, found {[c.name for c in cases]}"

    for case in cases:
        expected = json.loads((case / "expected.json").read_text())
        patch = case / "diff.patch"

        work = tmp_path / case.name
        work.mkdir()
        make_scripts(work)
        r = run(f'bash scripts/review.sh --diff-file "{patch}" --max-iterations 1', cwd=work)
        assert r.returncode == 0, f"{case.name}: review failed\n{r.stderr}\n{r.stdout}"

        score_line = [l for l in r.stdout.splitlines() if l.startswith("score:")]
        assert score_line, f"{case.name}: no score line in output\n{r.stdout}"
        score = int(score_line[0].split(":", 1)[1].strip())
        assert score == expected["score"], (
            f"{case.name}: expected score {expected['score']}, got {score}\n{r.stdout}"
        )

        lines = finding_lines(work)
        sample_dir = f"tests/fixtures/{case.name}/"
        strays = [l for l in lines if sample_dir not in l]
        assert not strays, f"{case.name}: finding outside the fixture path:\n" + "\n".join(strays)

        for want in expected["findings"]:
            where = f"{want['file']}:{want['line']} "
            match = [l for l in lines if where in l]
            assert match, (
                f"{case.name}: no finding at {want['file']}:{want['line']} in:\n" + "\n".join(lines)
            )
            # An installed linter may report extra rules on the same fixture, so the
            # recorded finding must be present, not necessarily alone.
            assert any(f"/{want['severity']}]" in l and want["contains"].lower() in l.lower()
                       for l in match), (
                f"{case.name}: expected a {want['severity']} finding mentioning "
                f"{want['contains']!r} at {where}, got:\n" + "\n".join(match)
            )

        print(f"ARTIFACT {case.name}: score {score}, findings:\n" + "\n".join(lines))


def test_k_gate_reflects_severity(tmp_path):
    # A critical finding must not pass the gate even with plenty of iterations left,
    # and a clean diff must pass on the first one without looping.
    for case, expect_pass in (("sqli", False), ("clean", True)):
        work = tmp_path / f"gate-{case}"
        work.mkdir()
        make_scripts(work)
        r = run(f'bash scripts/review.sh --diff-file "{FIXTURES / case / "diff.patch"}"', cwd=work)
        assert r.returncode == 0, r.stderr
        passed = "Gate passed" in r.stdout
        assert passed is expect_pass, f"{case}: gate passed={passed}, expected {expect_pass}\n{r.stdout}"
        if expect_pass:
            assert "Gate passed at iteration 1" in r.stdout, r.stdout


def test_k_unreadable_patch_is_rejected(tmp_path):
    work = tmp_path / "missing"
    work.mkdir()
    make_scripts(work)
    r = run("bash scripts/review.sh --diff-file does-not-exist.patch", cwd=work)
    assert r.returncode == 2, f"expected exit 2, got {r.returncode}"
    assert "not readable" in r.stderr, r.stderr
