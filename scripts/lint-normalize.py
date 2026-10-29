#!/usr/bin/env python3
"""Normalize linter JSON into review findings, keeping only ADDED lines.

Usage: lint-normalize.py <tool> <tool-json> <flat-records>

<tool>          ruff | eslint | gitleaks | semgrep
<tool-json>     the linter report, as written by detect.sh
<flat-records>  flatten_diff output: "<path>\t<new-line>\t<text>" for added lines

A finding is emitted only when the linter reports it on a line this change
actually added, so a pre-existing violation never inflates the score of a diff.
Output format matches detect.sh exactly:

    L: <path>:<line> [<axis>/<severity>] <reason> -> fix hint: <fix>

Any malformed report is treated as "no findings" - a broken linter must never
fail a review.
"""
import json
import sys

# ruff rule code -> (axis/severity, reason, fix)
RUFF_CODES = {
    "S608": ("security/critical", "query assembled by string concatenation", "use a parameterized query"),
    "S610": ("security/critical", "raw query call with untrusted input", "use a parameterized query"),
    "S105": ("security/critical", "credential literal in source", "read the value from the environment"),
    "S106": ("security/critical", "credential literal in argument", "read the value from the environment"),
    "S107": ("security/critical", "credential literal as default", "read the value from the environment"),
    "S301": ("security/high", "unsafe deserialization", "use a safe loader"),
    "S307": ("security/high", "unsafe eval", "remove eval"),
    "S324": ("security/high", "weak hash function", "use sha256"),
    "S311": ("security/medium", "non-cryptographic randomness", "use secrets for security decisions"),
    "F821": ("correctness/high", "undefined name", "define or import the name"),
    "B006": ("correctness/medium", "mutable default argument", "use None and build inside the body"),
    "E501": ("readability/nitpick", "line too long", "wrap the line"),
    "F401": ("readability/low", "unused import", "remove the import"),
    "F841": ("readability/low", "unused variable", "remove the variable"),
}

SEMGREP_SEVERITY = {
    "ERROR": "correctness/high",
    "WARNING": "correctness/medium",
    "INFO": "readability/low",
}


def normalise(path):
    return str(path or "").lstrip("./")


def load_added(flat_path):
    """Set of (path, new-line) pairs for the lines this diff added."""
    added = set()
    try:
        with open(flat_path, encoding="utf-8", errors="replace") as handle:
            for record in handle:
                parts = record.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    added.add((normalise(parts[0]), parts[1].strip()))
    except OSError:
        pass
    return added


def make_emitter(added):
    def emit(path, line, axis_sev, reason, fix):
        key = (normalise(path), str(line))
        if key not in added:
            return
        print(f"L: {normalise(path)}:{line} [{axis_sev}] {reason} -> fix hint: {fix}")

    return emit


def ruff(report, emit):
    for item in report or []:
        code = str(item.get("code") or "").strip()
        row = (item.get("location") or {}).get("row", 0)
        if code in RUFF_CODES:
            axis_sev, reason, fix = RUFF_CODES[code]
        elif code.startswith("S"):
            axis_sev, reason, fix = ("security/high", item.get("message", code), "address the security rule")
        elif code.startswith("B"):
            axis_sev, reason, fix = ("correctness/medium", item.get("message", code), "address the bugbear rule")
        else:
            axis_sev, reason, fix = ("readability/low", item.get("message", code), "address the lint rule")
        emit(item.get("filename", ""), row, axis_sev, f"{code} {reason}".strip(), fix)


def eslint(report, emit):
    for entry in report or []:
        path = entry.get("filePath", "")
        for message in entry.get("messages", []) or []:
            rule = message.get("ruleId") or "eslint"
            axis_sev = "correctness/high" if message.get("severity") == 2 else "readability/low"
            emit(path, message.get("line", 0), axis_sev,
                 f"{rule}: {message.get('message', '')}".strip(), "fix the reported rule")


def gitleaks(report, emit):
    for item in report or []:
        rule = item.get("RuleID", "secret")
        emit(item.get("File", ""), item.get("StartLine", 0), "security/critical",
             f"possible committed secret ({rule}) - {item.get('Description', '')}".strip(),
             "remove the secret, rotate it, load it from the environment")


def semgrep(report, emit):
    for item in report.get("results", []) or []:
        extra = item.get("extra") or {}
        check = item.get("check_id", "rule")
        axis_sev = SEMGREP_SEVERITY.get(str(extra.get("severity", "")).upper(), "correctness/medium")
        if "security" in str(check).lower():
            axis_sev = "security/high"
        emit(item.get("path", ""), (item.get("start") or {}).get("line", 0), axis_sev,
             f"{check}: {extra.get('message', '')}".strip(), "address the semgrep rule")


MAPPERS = {"ruff": ruff, "eslint": eslint, "gitleaks": gitleaks, "semgrep": semgrep}


def main(argv):
    if len(argv) != 4:
        return 0
    tool, report_path, flat_path = argv[1], argv[2], argv[3]
    mapper = MAPPERS.get(tool)
    if mapper is None:
        return 0
    try:
        with open(report_path, encoding="utf-8", errors="replace") as handle:
            report = json.load(handle)
    except (OSError, ValueError):
        return 0
    mapper(report, make_emitter(load_added(flat_path)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
