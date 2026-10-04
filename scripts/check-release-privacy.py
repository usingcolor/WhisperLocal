#!/usr/bin/env python3
"""Reject personal Mac account paths embedded in a distribution app."""
import argparse
import re
from pathlib import Path


# Hosted builds and anonymized examples use these neutral account names.
ALLOWED_ACCOUNTS = {b"runner", b"developer", b"Shared"}
HOME_PATH = re.compile(rb"/Users/([^/\x00\r\n]{1,128})/")


def check_app(app):
    if not app.is_dir() or not (app / "Contents" / "Info.plist").is_file():
        raise ValueError("expected a complete .app bundle")
    findings = []
    files_checked = 0
    for path in sorted(app.rglob("*")):
        if not path.is_file():
            continue
        data = path.read_bytes()
        files_checked += 1
        count = sum(
            match[1] not in ALLOWED_ACCOUNTS for match in HOME_PATH.finditer(data)
        )
        if count:
            findings.append((str(path.relative_to(app)), count))
    return files_checked, findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        files_checked, findings = check_app(args.app)
    except (OSError, ValueError):
        # Paths and account names may themselves be private; keep logs generic.
        parser.exit(1, "error: cannot read the complete distribution app\n")
    if findings:
        count = sum(count for _, count in findings)
        parser.exit(
            1,
            f"error: distribution blocked: {count} personal Mac account paths "
            f"in {len(findings)} files; rebuild on the hosted runner\n",
        )
    print(f"Distribution privacy check passed: {files_checked} files scanned.")


if __name__ == "__main__":
    main()
