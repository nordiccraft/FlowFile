#!/usr/bin/env python3
"""Extract human-readable release notes for a target version from CHANGELOG.md.

Falls back to git commit subjects since the previous tag if the version is not
explicitly listed in CHANGELOG.md.
"""

import pathlib
import re
import subprocess
import sys


def extract_from_changelog(changelog_path: pathlib.Path, version: str) -> str:
    if not changelog_path.is_file():
        return ""

    text = changelog_path.read_text(encoding="utf-8")
    escaped = re.escape(version.lstrip("vV"))
    header_pattern = re.compile(rf"^##\s+\[?v?{escaped}\]?(?:\s+-\s+.*)?$", re.MULTILINE)
    match = header_pattern.search(text)
    if not match:
        return ""

    rest = text[match.end():]
    next_header = re.search(r"^##\s+", rest, re.MULTILINE)
    section = rest[: next_header.start()] if next_header else rest

    cleaned_lines: list[str] = []
    for raw_line in section.strip().splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if stripped.startswith("- ") or stripped.startswith("* "):
            cleaned_lines.append("• " + stripped[2:].strip())
        else:
            cleaned_lines.append(line)

    return "\n".join(cleaned_lines).strip()


def fallback_from_git(version: str) -> str:
    tag = f"v{version.lstrip('vV')}"
    try:
        tags_out = subprocess.check_output(
            ["git", "tag", "--sort=-v:refname"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        tags = [t.strip() for t in tags_out.splitlines() if t.strip()]
        prev_tag = None
        for candidate in tags:
            if candidate != tag:
                prev_tag = candidate
                break

        rev_range = f"{prev_tag}..HEAD" if prev_tag else "-n 8 HEAD"
        cmd = ["git", "log", "--no-merges", "--pretty=format:%s"]
        if prev_tag:
            cmd.append(rev_range)
        else:
            cmd.extend(["-n", "8", "HEAD"])

        subjects = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).splitlines()
        bullets = [
            f"• {s.strip()}"
            for s in subjects
            if s.strip() and not s.strip().startswith("Oppdater Homebrew Cask")
        ]
        if bullets:
            return "\n".join(bullets[:10])
    except Exception:
        pass
    return f"• Feilrettinger og ytelsesforbedringer i FlowFile {version.lstrip('vV')}."


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: extract-release-notes.py <CHANGELOG.md> <version>", file=sys.stderr)
        return 1

    changelog_path = pathlib.Path(sys.argv[1])
    version = sys.argv[2].lstrip("vV")

    notes = extract_from_changelog(changelog_path, version)
    if not notes:
        notes = fallback_from_git(version)

    print(notes)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
