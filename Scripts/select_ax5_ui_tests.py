#!/usr/bin/env python3
"""List xcodebuild -only-testing identifiers for UI tests that exercise ax5.

AX5 (the largest accessibility Dynamic Type size) is pinned per test via
``OBOE_UI_TEST_DYNAMIC_TYPE = "ax5"`` launch environment. This script scans
``OboeUITests/*.swift`` and emits every ``func test*`` whose body mentions the
literal ``ax5``, one ``<TestTarget>/<Class>/<method>`` identifier per line,
so CI can run the accessibility-size slice without hard-coding test names.

Usage:
    python3 Scripts/select_ax5_ui_tests.py [UITESTS_DIR]

Convention: a test is picked up when the ``ax5`` literal appears inside its
own function body (inline launch-environment dictionaries included), or when
the body calls a helper function that itself sets ``"ax5"`` and the call
passes an enabling argument (``true`` or an ``ax5`` literal). Over-selection
is harmless — a wrongly selected test simply runs; silently missing real ax5
coverage is not.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


CLASS_RE = re.compile(r"\b(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase\b")
FUNC_RE = re.compile(r"\bfunc\s+(\w+)\s*\(")
TEST_FUNC_RE = re.compile(r"\bfunc\s+(test\w+)\s*\(")


def brace_delta(line: str) -> int:
    """Net { } change for a line, ignoring // comments and string literals."""
    stripped = []
    index = 0
    while index < len(line):
        if line.startswith("//", index):
            break
        if line[index] == '"':
            index += 1
            while index < len(line) and line[index] != '"':
                if line[index] == "\\":
                    index += 1
                index += 1
            index += 1
            continue
        stripped.append(line[index])
        index += 1
    text = "".join(stripped)
    return text.count("{") - text.count("}")


def function_body(lines: list[str], start: int) -> str:
    """Return the source of the function whose signature begins at ``start``."""
    depth = 0
    started = False
    body: list[str] = []
    for cursor in range(start, len(lines)):
        line = lines[cursor]
        body.append(line)
        depth += brace_delta(line)
        if "{" in line:
            started = True
        if started and depth <= 0:
            break
    return "\n".join(body)


def select_ax5_tests(directory: Path, target: str) -> list[str]:
    selected: list[str] = []
    for path in sorted(directory.glob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()

        # Pass 1: helper (non-test) functions whose own body can set ax5.
        ax5_helpers: set[str] = set()
        for line_index, line in enumerate(lines):
            func_match = FUNC_RE.search(line)
            if func_match and not func_match.group(1).startswith("test"):
                if "ax5" in function_body(lines, line_index):
                    ax5_helpers.add(func_match.group(1))

        # Pass 2: test methods inside XCTestCase classes.
        current_class: str | None = None
        for line_index, line in enumerate(lines):
            class_match = CLASS_RE.search(line)
            if class_match:
                current_class = class_match.group(1)
            test_match = TEST_FUNC_RE.search(line)
            if test_match and current_class:
                body = function_body(lines, line_index)
                if "ax5" in body:
                    selected.append(
                        f"{target}/{current_class}/{test_match.group(1)}"
                    )
                    continue
                calls_ax5_helper = any(
                    re.search(
                        rf"\b{re.escape(helper)}\s*\([^)]*(: true|\bax5\b)",
                        body,
                    )
                    for helper in ax5_helpers
                )
                if calls_ax5_helper:
                    selected.append(
                        f"{target}/{current_class}/{test_match.group(1)}"
                    )
    return selected


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory",
        nargs="?",
        default="OboeUITests",
        type=Path,
        help="directory containing the UI test sources (default: OboeUITests)",
    )
    parser.add_argument(
        "--target",
        default="OboeUITests",
        help="xcodebuild test target name (default: OboeUITests)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    if not args.directory.is_dir():
        print(f"select_ax5_ui_tests.py: not a directory: {args.directory}", file=sys.stderr)
        return 1
    selected = select_ax5_tests(args.directory, args.target)
    if not selected:
        print(
            "select_ax5_ui_tests.py: no ax5-marked UI tests found — "
            "refusing to produce an empty selection",
            file=sys.stderr,
        )
        return 1
    for identifier in selected:
        print(identifier)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
