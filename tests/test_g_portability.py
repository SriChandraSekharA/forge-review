"""Scenario G — Portability: no hardcoded dev paths + fresh-copy install + feedback.jsonl preservation.
# test: scenario G portability - no /Users/ in owned scripts, fresh copy runs init.sh at arbitrary path, feedback.jsonl line survives re-init + merge with state.json preserved
"""
import json
import pathlib
import shutil
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(cmd, cwd=None):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True)


def test_g_no_hardcoded_users_paths():
    # (a) grep-gate: no /Users/ absolute paths in the portability-owned scripts
    for name in ("init.sh", "merge.sh", "knowledge.sh"):
        text = (REPO_ROOT / "scripts" / name).read_text()
        assert "/Users/" not in text, f"hardcoded /Users/ path in scripts/{name}"


def test_g_fresh_copy_install_and_feedback_preserved(tmp_path):
    # (b) simulate an install at an arbitrary path (npx skills add copies scripts/ + references/)
    install = tmp_path / "installed-skill-anywhere"
    install.mkdir()
    shutil.copytree(REPO_ROOT / "scripts", install / "scripts")
    shutil.copytree(REPO_ROOT / "references", install / "references")

    work = tmp_path / "consumer-project"
    work.mkdir()
    init_sh = install / "scripts" / "init.sh"
    merge_sh = install / "scripts" / "merge.sh"

    # first init from the arbitrary install path
    r = run(f'bash "{init_sh}"', cwd=work)
    print(f"init stdout: {r.stdout}\ninit stderr: {r.stderr}\nrc: {r.returncode}")
    assert r.returncode == 0, f"init failed at arbitrary path: {r.stderr} {r.stdout}"
    mem = work / ".forge-standard-review"
    assert mem.is_dir(), ".forge-standard-review/ not created at fresh path"
    assert (mem / "state.json").exists(), "state.json missing after init"
    feedback = mem / "feedback.jsonl"
    assert feedback.exists(), "feedback.jsonl not created by init.sh"

    # user memory: one learned feedback line
    fb_line = '{"type":"dismiss","path":"src/app.py","rule":"owasp/sqli","reason":"parameterized"}'
    with open(feedback, "a") as f:
        f.write(fb_line + "\n")
    state_before = (mem / "state.json").read_text()
    json.loads(state_before)  # sanity: valid JSON before re-run

    # re-run init.sh + merge.sh on the existing instance (never-lose-data contract)
    r2 = run(f'bash "{init_sh}"', cwd=work)
    assert r2.returncode == 0, f"re-init failed: {r2.stderr} {r2.stdout}"
    r3 = run(f'bash "{merge_sh}"', cwd=work)
    assert r3.returncode == 0, f"merge failed: r3.stderr {r3.stderr} {r3.stdout}"

    # feedback line survives, exactly once (no dupes, no truncation)
    content = feedback.read_text()
    print(f"feedback.jsonl after re-init/merge: {content!r}")
    assert content.count(fb_line) == 1, f"feedback line lost or duplicated: {content!r}"

    # state.json preserved: still valid JSON, initialized, reviews intact
    state_after_text = (mem / "state.json").read_text()
    assert state_after_text.strip(), "state.json truncated on re-init"
    state_after = json.loads(state_after_text)
    assert state_after.get("initialized") is True
    reviews_before = json.loads(state_before).get("reviews", [])
    assert state_after.get("reviews", []) == reviews_before, "reviews[] not preserved"

    # foreign-line merge: dedupe via merge.sh $2 source (exact-line dedupe, order preserved)
    foreign = work / "foreign-feedback.jsonl"
    new_line = '{"type":"preference","rule":"readability/nitpick","reason":"keep"}'
    foreign.write_text(fb_line + "\n" + new_line + "\n")
    r4 = run(f'bash "{merge_sh}" "{mem}" "{foreign}"', cwd=work)
    assert r4.returncode == 0, f"merge with foreign source failed: {r4.stderr}"
    merged = feedback.read_text().strip().splitlines()
    assert merged.count(fb_line) == 1, f"foreign duplicate not deduped: {merged}"
    assert new_line in merged, f"foreign new line not appended: {merged}"
    assert merged.index(fb_line) < merged.index(new_line), "order not preserved"


def test_g_init_idempotent_at_fresh_path_no_reference_leak(tmp_path):
    # knowledge.sh must not reach back into a dev-machine path: with no repo docs at all,
    # a fresh copy still self-heals via its own references/ (Fowler fallback or reference copy)
    install = tmp_path / "skill-copy"
    install.mkdir()
    shutil.copytree(REPO_ROOT / "scripts", install / "scripts")
    shutil.copytree(REPO_ROOT / "references", install / "references")
    work = tmp_path / "bare-project"
    work.mkdir()
    r = run(f'bash "{install / "scripts" / "init.sh"}"', cwd=work)
    assert r.returncode == 0, r.stderr + r.stdout
    know = (work / ".forge-standard-review" / "knowledge.md")
    assert know.exists(), "knowledge.md missing on fresh-copy init"
    text = know.read_text()
    assert "/Users/" not in text, "knowledge.md leaked a dev-machine path"
    assert len(text) > 0
