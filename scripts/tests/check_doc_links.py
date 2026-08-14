#!/usr/bin/env python3
"""Fail when a repository Markdown link points at a missing local path."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
SKIP_PARTS = {".git", ".lake", ".cache"}
LINK = re.compile(
    r"!?\[[^\]]*\]\(([^)\s]+)\)|^\s*\[[^\]]+\]:\s*(\S+)",
    re.MULTILINE,
)
EXTERNAL_PREFIXES = ("#", "http://", "https://", "mailto:", "@/")


def main() -> int:
    failures: list[tuple[Path, int, str]] = []
    checked = 0

    for path in ROOT.rglob("*.md"):
        relative = path.relative_to(ROOT)
        if any(part in SKIP_PARTS for part in relative.parts):
            continue
        text = path.read_text(errors="replace")
        for match in LINK.finditer(text):
            target = match.group(1) or match.group(2)
            if target.startswith(EXTERNAL_PREFIXES):
                continue
            local = target.split("#", 1)[0]
            if not local:
                continue
            checked += 1
            if not (path.parent / local).resolve().exists():
                line = text.count("\n", 0, match.start()) + 1
                failures.append((relative, line, target))

    for path, line, target in failures:
        print(f"FAIL {path}:{line}: missing local link {target}")
    if failures:
        print(f"DOC-LINKS: FAIL={len(failures)} CHECKED={checked}")
        return 1
    print(f"DOC-LINKS: PASS CHECKED={checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
