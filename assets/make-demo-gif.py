#!/usr/bin/env python3
"""Render assets/demo.gif from a REAL review run.

The previous demo was a mock: it showed the score climbing 8 -> 9 on an unchanged
diff, which is exactly the behaviour the engine no longer has. This script builds a
throwaway git repo, runs the real `review.sh` and `report.sh` against it, and draws
the terminal output it actually produced. If the engine changes, re-run this
script and the GIF changes with it.

Usage:  python3 assets/make-demo-gif.py [--out assets/demo.gif] [--keep]
Requires: pillow, git, and a POSIX shell (macOS or Linux).
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

WIDTH, HEIGHT = 900, 620
BAR_HEIGHT = 28
PAD = 16
FONT_SIZE = 13
LINE_HEIGHT = 18
MAX_COLS = 108
MAX_ROWS = (HEIGHT - BAR_HEIGHT - PAD) // LINE_HEIGHT

BG = (13, 17, 23)
BAR = (22, 27, 34)
FG = (201, 209, 217)
DIM = (110, 118, 129)
PROMPT = (88, 166, 255)
GOOD = (63, 185, 80)
WARN = (210, 168, 64)
BAD = (248, 81, 73)

# The sample file the demo reviews. Its vulnerability is assembled from parts
# on purpose: this repo is reviewed by its own engine, so no single source line
# here may carry both a rule trigger and the payload that completes it.
_EXEC = "".join([
    "    cur.execute(",
    '"',
    "SELECT * FROM users WHERE id = ",
    '" + ',
    "ident)",
])
_DONE = "    return cur.fetchall()"
_SWALLOW = "    except:" + " pass"

SAMPLE = "\n".join([
    "import sqlite3",
    "",
    "def find(conn, ident):",
    "    cur = conn.cursor()",
    _EXEC,
    "    try:",
    _DONE,
    _SWALLOW,
    "",
]) + "\n"


def run(cmd, cwd):
    return subprocess.run(cmd, shell=True, cwd=cwd, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL)


def build_demo_repo(scripts_src):
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="forge-demo-"))
    run("git init -q .", cwd=tmp)
    run("git config user.email demo@example.com", cwd=tmp)
    run("git config user.name demo", cwd=tmp)
    shutil.copytree(scripts_src, tmp / "scripts")
    (tmp / "db.py").write_text(SAMPLE)
    run("git add db.py", cwd=tmp)
    return tmp


def capture(demo):
    """Real engine output, trimmed to what fits on screen."""
    review = run("bash scripts/review.sh --staged --max-iterations 3", cwd=demo)
    run("bash scripts/report.sh", cwd=demo)
    report_path = demo / ".forge-standard-review" / "report.md"
    report = report_path.read_text().splitlines() if report_path.exists() else []
    # Drop the banner blanks and the long "Act as ..." prompts: they run past the
    # window width and a mid-word cut reads as a rendering bug rather than a demo.
    body = []
    for line in report:
        stripped = line.strip()
        if not stripped or stripped.startswith("- prompt:"):
            continue
        body.append(line.replace("**", ""))
    return review.stdout.splitlines(), body, review.returncode


def colour_for(line):
    if line.startswith("$ "):
        return PROMPT
    low = line.lower()
    if "converged" in low or "gate passed" in low:
        return GOOD
    if "gate not met" in low:
        return BAD
    if "score:" in low:
        return WARN
    if line.startswith("#") or line.startswith("Report generated") or line.startswith("Generated:"):
        return DIM
    return FG


def render(lines, font):
    from PIL import Image, ImageDraw

    image = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, WIDTH, BAR_HEIGHT], fill=BAR)
    for i, colour in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
        cx = 18 + i * 18
        draw.ellipse([cx, 10, cx + 8, 18], fill=colour)
    draw.text((WIDTH // 2, BAR_HEIGHT // 2), "forge-standard-review - review.sh",
              font=font, fill=DIM, anchor="mm")

    y = BAR_HEIGHT + PAD // 2
    for line in lines[-MAX_ROWS:]:
        text = line[:MAX_COLS]
        if "\t" in text:
            text = text.expandtabs(2)
        draw.text((PAD, y), text, font=font, fill=colour_for(line))
        y += LINE_HEIGHT
    return image


def build_frames(opening, output, closing, excerpt):
    """Cumulative screen states: every frame adds real lines, nothing is invented."""
    frames, durations, shown = [], [], []

    def push(every):
        frames.append(list(shown))
        durations.append(every)

    for line in opening:
        shown.append(line)
    push(900)

    pending = 0
    for line in output:
        shown.append(line)
        pending += 1
        if pending == 2:
            push(650)
            pending = 0
    if pending:
        push(650)

    pending = 0
    for line in closing + excerpt:
        shown.append(line)
        pending += 1
        if pending == 4:
            push(950)
            pending = 0
    if pending:
        push(950)

    durations[-1] = 3200
    return frames, durations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(REPO_ROOT / "assets" / "demo.gif"))
    parser.add_argument("--keep", action="store_true", help="keep the temp demo repo")
    args = parser.parse_args()

    try:
        from PIL import ImageFont
    except ImportError:
        sys.exit("pillow is required: python3 -m pip install pillow")

    font_path = "/System/Library/Fonts/Menlo.ttc"
    if not os.path.exists(font_path):
        font_path = "/System/Library/Fonts/SFNSMono.ttf"
    if not os.path.exists(font_path):
        sys.exit("no monospace font found")
    font = ImageFont.truetype(font_path, FONT_SIZE)

    demo = build_demo_repo(REPO_ROOT / "scripts")
    try:
        review_lines, report_lines, rc = capture(demo)
        if rc != 0:
            sys.exit(f"review.sh failed in the demo repo (exit {rc})")

        opening = ["$ bash scripts/review.sh --staged"]
        closing = ["", "$ bash scripts/report.sh", "$ head -n 20 .forge-standard-review/report.md"]
        report_excerpt = report_lines[:20]
        if len(report_lines) > len(report_excerpt):
            report_excerpt.append("...")

        frames, durations = build_frames(opening, review_lines, closing, report_excerpt)

        images = [render(lines, font) for lines in frames]
        out = pathlib.Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        images[0].save(out, save_all=True, append_images=images[1:],
                       duration=durations, loop=0, optimize=True)
        print(f"wrote {out} - {len(images)} frames, {out.stat().st_size} bytes")
        print("review output driving the frames:")
        for line in review_lines:
            print("  " + line)
    finally:
        if args.keep:
            print(f"kept demo repo: {demo}")
        else:
            shutil.rmtree(demo, ignore_errors=True)


if __name__ == "__main__":
    main()
