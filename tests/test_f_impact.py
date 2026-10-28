"""Scenario F — Impact tracing: blast radius beyond the diff (Greptile-inspired).
impact.sh importers/kinds/caps + report.sh Impact section + review.json impact key.
Real bash, real grep/git grep, no mocks, no network.
# test: scenario F impact - impact.sh finds importers with kinds, caps 50 per file + "... N more", report.md gains Impact section before ranked sections, review.json gains additive impact key
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
    """git repo + only the scripts under test copied in (report.sh invokes impact.sh script-relatively)."""
    r = run("git init", cwd=tmp)
    assert r.returncode == 0, r.stderr
    run("git config user.email test@test.com", cwd=tmp)
    run("git config user.name test", cwd=tmp)
    (tmp / "scripts").mkdir()
    for name in ("report.sh", "impact.sh"):
        shutil.copy2(SCRIPTS / name, tmp / "scripts" / name)
    return tmp


def test_f_impact_importers_and_kinds(tmp_path):
    # (a) impact.sh --files finds both importers with right kinds; stdin mode too
    tmp = tmp_path / "impact"
    tmp.mkdir()
    make_repo(tmp)
    (tmp / "lib.py").write_text("def helper():\n    return 1\n")
    (tmp / "importer_a.py").write_text("import lib\n\nprint(lib.helper())\n")
    (tmp / "importer_b.py").write_text("from lib import helper\n\nprint(helper())\n")
    r = run("bash scripts/impact.sh --files lib.py", cwd=tmp)
    assert r.returncode == 0, f"impact.sh failed: {r.stderr}"
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    assert "IMPACT lib.py <- importer_a.py:1 import" in lines, r.stdout
    assert "IMPACT lib.py <- importer_b.py:1 import" in lines, r.stdout
    assert "IMPACT none" not in lines
    # require/include/reference kinds classified (lib.helper() bare mention -> reference)
    assert any(l.startswith("IMPACT lib.py <- importer_a.py:3 reference") for l in lines), r.stdout
    # stdin mode: one path per line
    r2 = run("echo lib.py | bash scripts/impact.sh", cwd=tmp)
    assert r2.returncode == 0, r2.stderr
    assert "IMPACT lib.py <- importer_a.py:1 import" in r2.stdout
    assert "IMPACT lib.py <- importer_b.py:1 import" in r2.stdout
    # empty result -> IMPACT none, exit 0
    (tmp / "orphan.py").write_text("x = 1\n")
    r3 = run("bash scripts/impact.sh --files orphan.py", cwd=tmp)
    assert r3.returncode == 0, r3.stderr
    assert r3.stdout.strip() == "IMPACT none", r3.stdout
    # committed tree: git grep merge must not duplicate or lose results
    run("git add -A", cwd=tmp)
    run("git commit -m init", cwd=tmp)
    r4 = run("bash scripts/impact.sh --files lib.py", cwd=tmp)
    assert r4.returncode == 0, r4.stderr
    assert "IMPACT lib.py <- importer_a.py:1 import" in r4.stdout, r4.stdout
    assert "IMPACT lib.py <- importer_b.py:1 import" in r4.stdout, r4.stdout
    dups = [l for l in r4.stdout.splitlines() if l == "IMPACT lib.py <- importer_a.py:1 import"]
    assert len(dups) == 1, f"git grep/grep merge duplicated: {dups}"
    print(f"ARTIFACT impact.sh stdout (committed):\n{r4.stdout}")


def test_f_impact_caps(tmp_path):
    # (b) 60 importers -> exactly 50 IMPACT lines + one "... 10 more" line
    tmp = tmp_path / "caps"
    tmp.mkdir()
    make_repo(tmp)
    (tmp / "corelib.py").write_text("def x():\n    return 1\n")
    for i in range(60):
        (tmp / f"importer_{i:02d}.py").write_text("from corelib import x\n")
    r = run("bash scripts/impact.sh --files corelib.py", cwd=tmp)
    assert r.returncode == 0, r.stderr
    lines = [l for l in r.stdout.splitlines() if l.strip()]
    impact_lines = [l for l in lines if l.startswith("IMPACT ")]
    assert len(impact_lines) == 50, f"expected 50 impact lines, got {len(impact_lines)}"
    assert lines[-1] == "... 10 more", f"expected '... 10 more' last, got: {lines[-3:]}"
    print(f"ARTIFACT caps: {len(lines)} lines, tail: {lines[-2:]}")


def test_f_report_impact_section(tmp_path):
    # (c) report.sh emits Impact section before ranked sections; review.json gains impact key, old keys unchanged
    tmp = tmp_path / "report"
    tmp.mkdir()
    make_repo(tmp)
    (tmp / "lib.py").write_text("def helper():\n    return 1\n")
    (tmp / "importer_a.py").write_text("import lib\n")
    (tmp / "importer_b.py").write_text("from lib import helper\n")
    # findings via learning.md (lives in excluded .forge-standard-review dir, like real runs)
    fsdir = tmp / ".forge-standard-review"
    fsdir.mkdir()
    (fsdir / "learning.md").write_text(
        "L: lib.py:1 [security/high] unsafe helper -> validate input\n"
        "L: lib.py:2 [readability/low] missing docstring -> add docstring\n"
    )
    r = run("bash scripts/report.sh", cwd=tmp)
    assert r.returncode == 0, f"report.sh failed: {r.stderr} {r.stdout}"
    report = (tmp / ".forge-standard-review" / "report.md").read_text()
    assert "## Impact (beyond the diff)" in report, report
    assert "IMPACT lib.py <- importer_a.py:1 import" in report, report
    assert "IMPACT lib.py <- importer_b.py:1 import" in report, report
    imp_idx = report.index("## Impact (beyond the diff)")
    sev_idxs = [i for i in (report.find("## High"), report.find("## Low")) if i >= 0]
    assert sev_idxs, f"no ranked sections found: {report[:500]}"
    assert imp_idx < min(sev_idxs), "Impact section must precede ranked severity sections"
    # review.json: additive impact key, old shape unchanged, jq-valid
    r_jq = run("jq . .forge-standard-review/review.json > /dev/null && echo jq_ok", cwd=tmp)
    assert "jq_ok" in r_jq.stdout, f"jq failed: {r_jq.stderr}"
    data = json.loads((tmp / ".forge-standard-review" / "review.json").read_text())
    assert "findings" in data, data
    assert len(data["findings"]) == 2, data
    for f in data["findings"]:
        for key in ("file", "line", "severity", "reason", "fix", "prompt"):
            assert key in f, f"missing {key} in {f}"
    imp = data.get("impact")
    assert isinstance(imp, list) and len(imp) == 2, f"unexpected impact: {imp}"
    for triple in imp:
        assert isinstance(triple, list) and len(triple) == 3, triple
    pairs = {(t[0], t[1], t[2]) for t in imp}
    assert ("lib.py", "importer_a.py:1", "import") in pairs, imp
    assert ("lib.py", "importer_b.py:1", "import") in pairs, imp
    print(f"ARTIFACT review.json impact: {imp}\nARTIFACT report.md impact section:\n{report[imp_idx:imp_idx+300]}")


def test_f_report_no_importers_omits_section(tmp_path):
    # (d) zero importers -> section omitted entirely, review.json impact == []
    tmp = tmp_path / "orphan"
    tmp.mkdir()
    make_repo(tmp)
    (tmp / "orphan_module_xyz.py").write_text("value = 1\n")
    fsdir = tmp / ".forge-standard-review"
    fsdir.mkdir()
    (fsdir / "learning.md").write_text(
        "L: orphan_module_xyz.py:1 [quality/medium] smell here -> refactor it\n"
    )
    r = run("bash scripts/report.sh", cwd=tmp)
    assert r.returncode == 0, f"report.sh failed: {r.stderr} {r.stdout}"
    report = (tmp / ".forge-standard-review" / "report.md").read_text()
    assert "## Impact (beyond the diff)" not in report, report
    assert "IMPACT " not in report, report
    data = json.loads((tmp / ".forge-standard-review" / "review.json").read_text())
    assert data.get("impact") == [], f"expected empty impact array: {data.get('impact')}"
    assert "findings" in data and len(data["findings"]) == 1, data
    print(f"ARTIFACT orphan report.md head:\n{report[:400]}\nARTIFACT review.json:\n{json.dumps(data)[:400]}")


def test_f_report_without_impact_sh(tmp_path):
    # tolerate impact.sh absence: report still generates, no Impact section, impact == []
    tmp = tmp_path / "noimpact"
    tmp.mkdir()
    run("git init", cwd=tmp)
    run("git config user.email test@test.com", cwd=tmp)
    run("git config user.name test", cwd=tmp)
    (tmp / "scripts").mkdir()
    shutil.copy2(SCRIPTS / "report.sh", tmp / "scripts" / "report.sh")
    (tmp / "lib.py").write_text("def helper():\n    return 1\n")
    (tmp / "importer_a.py").write_text("import lib\n")
    findings = {"findings": [
        {"file": "lib.py", "line": 1, "severity": "high", "reason": "unsafe helper", "fix": "validate input"},
    ]}
    (tmp / "issue_input.json").write_text(json.dumps(findings))
    r = run("bash scripts/report.sh --input issue_input.json", cwd=tmp)
    assert r.returncode == 0, f"report.sh failed: {r.stderr} {r.stdout}"
    report = (tmp / ".forge-standard-review" / "report.md").read_text()
    assert "## Impact (beyond the diff)" not in report, report
    data = json.loads((tmp / ".forge-standard-review" / "review.json").read_text())
    assert data.get("impact") == [], data
    assert len(data["findings"]) == 1, data
