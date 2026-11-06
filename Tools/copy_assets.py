#!/usr/bin/env python3
"""Copy explicit project assets without Finder metadata or hidden files."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).resolve()
target = Path(sys.argv[2]).resolve()
for path in source.rglob("*"):
    relative = path.relative_to(source)
    if any(part.startswith(".") for part in relative.parts) or not path.is_file():
        continue
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(path.read_bytes())
