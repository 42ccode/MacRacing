#!/usr/bin/env python3
"""Synchronize bundled project assets without Finder metadata or hidden files."""
from pathlib import Path
from shutil import copyfile
import sys

source = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2]).resolve()
if source.is_relative_to(target) or target.is_relative_to(source):
    raise SystemExit("Asset source and destination must be separate directories")

files = {path.relative_to(source): path for path in source.rglob("*")
         if not any(part.startswith(".") for part in path.relative_to(source).parts)
         and path.is_file()}
if not files:
    raise SystemExit(f"No project assets found in {source}")

target.mkdir(parents=True, exist_ok=True)
for relative, path in files.items():
    destination = target / relative
    if any(parent.is_symlink() for parent in destination.parents if parent.is_relative_to(target)):
        raise SystemExit(f"Asset destination contains a symbolic-link directory: {destination.parent}")
    if destination.is_symlink():
        destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    copyfile(path, destination)

for path in sorted(target.rglob("*"), key=lambda entry: len(entry.parts), reverse=True):
    if path.is_symlink() or path.is_file():
        if path.relative_to(target) not in files:
            path.unlink()
    elif path.is_dir() and not any(path.iterdir()):
        path.rmdir()
