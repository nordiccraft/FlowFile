#!/usr/bin/env python3
"""Updates only `version` and `sha256` in-place inside Casks/flowfile.rb."""

import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: update-cask.py <cask-file> <version> <sha256>", file=sys.stderr)
        return 2

    cask_path = pathlib.Path(sys.argv[1])
    version = sys.argv[2].lstrip("v")
    sha256 = sys.argv[3].strip().lower()

    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        print(f"Invalid SHA-256 digest: {sha256}", file=sys.stderr)
        return 1

    original = cask_path.read_text(encoding="utf-8")

    updated, n_ver = re.subn(
        r'(^\s*version\s+)"[^"]*"',
        rf'\g<1>"{version}"',
        original,
        count=1,
        flags=re.MULTILINE,
    )
    updated, n_sha = re.subn(
        r'(^\s*sha256\s+)(?::no_check|"[^"]*")',
        rf'\g<1>"{sha256}"',
        updated,
        count=1,
        flags=re.MULTILINE,
    )

    if n_ver != 1 or n_sha != 1:
        print("Failed to locate `version` or `sha256` stanza in cask file.", file=sys.stderr)
        return 1

    cask_path.write_text(updated, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
