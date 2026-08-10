#!/usr/bin/env python3
"""
verify-diff-vectors.py — reference implementation of DiffEngine.

This is a line-for-line transcription of Sources/AgentiaCore/DiffEngine.swift.
It exists so the algorithm can be executed and inspected on a machine without a
Swift toolchain, and so the expected values in diff-vectors.json are produced by
running the algorithm rather than being written out by hand.

Run with --emit to regenerate the vector file, or with no arguments to check
that the committed vectors still match.

    python3 tools/verify-diff-vectors.py            # check
    python3 tools/verify-diff-vectors.py --emit     # regenerate
"""

import json
import os
import sys

QUADRATIC_LIMIT = 2000

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VECTORS = os.path.join(ROOT, "Tests", "AgentiaCoreTests", "Fixtures", "diff-vectors.json")


def split_lines(text):
    if text == "":
        return []
    normalised = text.replace("\r\n", "\n").replace("\r", "\n")
    if normalised.endswith("\n"):
        normalised = normalised[:-1]
    return normalised.split("\n")


def edit_script(old, new):
    """LCS table walk, matching the Swift implementation's tie-breaking."""
    n, m = len(old), len(new)
    table = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            if old[i] == new[j]:
                table[i][j] = table[i + 1][j + 1] + 1
            else:
                table[i][j] = max(table[i + 1][j], table[i][j + 1])

    script = []
    i = j = 0
    while i < n and j < m:
        if old[i] == new[j]:
            script.append("keep"); i += 1; j += 1
        elif table[i + 1][j] >= table[i][j + 1]:
            script.append("delete"); i += 1
        else:
            script.append("insert"); j += 1
    while i < n:
        script.append("delete"); i += 1
    while j < m:
        script.append("insert"); j += 1
    return script


def coalesce(script, offset):
    ranges = []
    new_line = offset
    run_start = None
    run_had_deletion = False
    pending_deletion = False

    def close_run():
        nonlocal run_start, run_had_deletion
        if run_start is None:
            return
        ranges.append({
            "start": run_start + 1,
            "end": new_line,
            "kind": "modified" if run_had_deletion else "added",
        })
        run_start = None
        run_had_deletion = False

    for edit in script:
        if edit == "keep":
            close_run()
            pending_deletion = False
            new_line += 1
        elif edit == "insert":
            if run_start is None:
                run_start = new_line
                run_had_deletion = pending_deletion
            pending_deletion = False
            new_line += 1
        else:  # delete
            if run_start is not None:
                run_had_deletion = True
            pending_deletion = True
    close_run()
    return ranges


def changes(old_text, new_text):
    old = split_lines(old_text)
    new = split_lines(new_text)

    if not old and not new:
        return []
    if not old:
        return []
    if not new:
        return []

    head = 0
    max_head = min(len(old), len(new))
    while head < max_head and old[head] == new[head]:
        head += 1

    tail = 0
    while tail < (max_head - head) and old[len(old) - 1 - tail] == new[len(new) - 1 - tail]:
        tail += 1

    old_mid = old[head:len(old) - tail]
    new_mid = new[head:len(new) - tail]

    if not old_mid and not new_mid:
        return []
    if not old_mid:
        return [{"start": head + 1, "end": head + len(new_mid), "kind": "added"}]
    if not new_mid:
        return []
    if len(old_mid) > QUADRATIC_LIMIT or len(new_mid) > QUADRATIC_LIMIT:
        return [{"start": head + 1, "end": head + len(new_mid), "kind": "modified"}]

    return coalesce(edit_script(old_mid, new_mid), head)


# --------------------------------------------------------------------------

CASES = [
    ("identical documents produce no ranges",
     "# Title\n\nBody.\n", "# Title\n\nBody.\n"),

    ("appended section is added, not modified",
     "# Title\n\nBody.\n",
     "# Title\n\nBody.\n\n## New\n\nMore.\n"),

    ("replaced line is modified",
     "# Title\n\nOld body.\n",
     "# Title\n\nNew body.\n"),

    ("insertion in the middle is added",
     "line one\nline three\n",
     "line one\nline two\nline three\n"),

    ("deletion alone produces no range",
     "keep\ndrop\nkeep two\n",
     "keep\nkeep two\n"),

    ("replacement of several lines by fewer",
     "a\nb\nc\nd\ne\n",
     "a\nX\ne\n"),

    ("replacement of few lines by several",
     "a\nX\ne\n",
     "a\nb\nc\nd\ne\n"),

    ("two separate changes yield two ranges",
     "a\nb\nc\nd\ne\nf\ng\n",
     "a\nB\nc\nd\ne\nF\ng\n"),

    ("prepended content is added at line 1",
     "existing\n",
     "brand new\nexisting\n"),

    ("empty old document yields nothing (first open)",
     "", "# Anything\n\nBody.\n"),

    ("empty new document yields nothing",
     "# Anything\n", ""),

    ("CRLF rewrite alone is not a change",
     "a\nb\nc\n", "a\r\nb\r\nc\r\n"),

    ("trailing newline added is not a change",
     "a\nb", "a\nb\n"),

    ("whole document replaced",
     "old one\nold two\n", "new one\nnew two\n"),

    ("realistic agent rewrite: table row updated and section appended",
     "# Report\n\n| m | v |\n| - | - |\n| a | 1 |\n\nDone.\n",
     "# Report\n\n| m | v |\n| - | - |\n| a | 2 |\n\nDone.\n\n## Notes\n\nAdded.\n"),
]


def build():
    out = {
        "_comment": ("Generated by tools/verify-diff-vectors.py. Expected values are "
                     "produced by running the reference implementation, not written "
                     "by hand. AgentiaCoreTests asserts the same vectors."),
        "quadraticLimit": QUADRATIC_LIMIT,
        "cases": [],
    }
    for name, old, new in CASES:
        out["cases"].append({
            "name": name,
            "old": old,
            "new": new,
            "expected": changes(old, new),
        })
    return out


def main():
    emit = "--emit" in sys.argv
    built = build()

    if emit:
        os.makedirs(os.path.dirname(VECTORS), exist_ok=True)
        with open(VECTORS, "w") as f:
            json.dump(built, f, indent=2)
            f.write("\n")
        print(f"wrote {VECTORS}")
    else:
        if not os.path.exists(VECTORS):
            print("vectors missing; run with --emit")
            return 1
        with open(VECTORS) as f:
            committed = json.load(f)
        if committed["cases"] != built["cases"]:
            print("MISMATCH: committed vectors differ from the reference output")
            return 1
        print(f"{len(built['cases'])} vectors match the reference implementation")

    print()
    for case in built["cases"]:
        ranges = ", ".join(
            f"{r['start']}-{r['end']} {r['kind']}" for r in case["expected"]
        ) or "(none)"
        print(f"  {case['name']:52s} -> {ranges}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
