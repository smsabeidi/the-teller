#!/usr/bin/env python3
"""Back up a stopped The Teller instance, including its SQLite account database."""
import argparse
import os
import tarfile
import tempfile
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--data", type=Path, default=Path("data"), help="the configured VOICEEMO_DATA_DIR")
    args = parser.parse_args()
    source = args.data.resolve()
    destination = args.destination.expanduser().resolve()
    if not source.is_dir() or not (source / "accounts.sqlite3").is_file():
        parser.error("the chosen directory doesn't contain an account database")
    if destination.exists() or destination.is_relative_to(source):
        parser.error("choose a new destination outside the data directory")

    os.umask(0o077)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as handle:
        temporary = Path(handle.name)
    try:
        with tarfile.open(temporary, "w:gz") as archive:
            archive.add(source, arcname="data")
        os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Backup saved to {destination}")


if __name__ == "__main__":
    main()
