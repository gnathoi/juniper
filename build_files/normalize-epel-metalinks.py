#!/usr/bin/env python3
"""Resolve EPEL's conditional stream suffix for rpm-ostree countme.

The reporter only expands $releasever and $basearch. Resolve the conditional
using the image's OS version, preserving every other repository option.
"""
from pathlib import Path
import re
import sys


def normalize(version, directory):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", version):
        raise ValueError(f"unsupported release version: {version}")
    suffix = "-z" if "." in version else ""
    for path in Path(directory).glob("epel*.repo"):
        original = path.read_text()
        updated = "".join(
            line.replace("${releasever_minor:+-z}", suffix)
            if re.match(r"\s*metalink\s*=", line) else line
            for line in original.splitlines(keepends=True)
        )
        if updated != original:
            path.write_text(updated)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: normalize-epel-metalinks.py VERSION_ID REPO_DIRECTORY")
    try:
        normalize(sys.argv[1], sys.argv[2])
    except ValueError as error:
        raise SystemExit(str(error))
