#!/usr/bin/env python3
"""Check local release metadata, without building or publishing anything."""
import argparse
import re
from pathlib import Path


def check(root, tag=None):
    project = (root / "project.yml").read_text()
    match = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', project, re.M)
    if not match or not re.fullmatch(r"\d+\.\d+\.\d+", match[1]):
        raise ValueError("project.yml needs a three-part MARKETING_VERSION")
    version = match[1]
    expected_tag = "v" + version
    if tag is not None and tag != expected_tag:
        raise ValueError(f"tag {tag!r} does not match {expected_tag}")
    build = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"([1-9]\d*)"\s*$', project, re.M)
    if not build:
        raise ValueError("project.yml needs a positive CURRENT_PROJECT_VERSION")

    notes = (root / ".github/release-notes.md").read_text()
    headings = re.findall(r"^## (\S+)", notes, re.M)
    if not headings or headings[0] != version or headings.count(version) != 1:
        raise ValueError(f"release notes must start with exactly one ## {version} section")
    if "{{SIGNING_SECTION}}" not in notes:
        raise ValueError("release notes need the signing placeholder")

    readme = (root / "README.md").read_text()
    links = re.findall(r"releases/download/v[0-9.]+/WhisperLocal-[0-9.]+-arm64\.dmg", readme)
    expected = f"releases/download/{expected_tag}/WhisperLocal-{version}-arm64.dmg"
    if not links or any(link != expected for link in links):
        raise ValueError(f"all README download links must point to {expected}")
    print(f"Ready to build {expected_tag} ({build[1]}): release notes and {len(links)} download links agree.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", help="Also verify an intended release tag")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    try:
        check(args.root, args.tag)
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
