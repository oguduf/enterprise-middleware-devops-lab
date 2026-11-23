#!/usr/bin/env python3
"""Check that an input artifact is a readable, structurally valid WAR archive."""

import argparse
import sys
import zipfile
from pathlib import Path


def validate(path: Path) -> str | None:
    if path.suffix.lower() != ".war":
        return "filename must end in .war"
    try:
        if not path.is_file() or path.stat().st_size == 0:
            return "file is missing or empty"
        with zipfile.ZipFile(path) as archive:
            if not any(name.upper().startswith("WEB-INF/") for name in archive.namelist()):
                return "archive has no WEB-INF content and does not look like a WAR"
            corrupt_member = archive.testzip()
            if corrupt_member is not None:
                return f"archive CRC check failed for {corrupt_member}"
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        return f"not a readable ZIP/WAR archive: {exc}"
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("war", type=Path, help="WAR file to validate")
    args = parser.parse_args(argv)
    error = validate(args.war)
    if error:
        print(f"[ERROR] {args.war}: {error}", file=sys.stderr)
        return 1
    print(f"[INFO] WAR archive is valid: {args.war}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
