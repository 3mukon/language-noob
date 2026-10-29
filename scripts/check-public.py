#!/usr/bin/env python3
"""Generic publishability checks, with no maintainer-specific vocabulary."""
import os
from pathlib import Path
import re
import sys

PATTERN = re.compile(rb'(?<![A-Za-z0-9_])(?:REQ|PLAN|DEC|REV|NOTE)-[0-9]{4}|visibility:\s*private|/(?:Users|home)/[^/\s]+/|' + rb'deliberation' + rb'/')
root = Path(sys.argv[1]).resolve()
for base, dirs, names in os.walk(root):
    dirs[:] = [d for d in dirs if d not in {'.git', '.build', 'build', 'dist', 'node_modules', '__pycache__', 'DerivedData'}]
    for name in names:
        path = Path(base)/name
        rel = path.relative_to(root).as_posix()
        if (name == '.env' or name.startswith('.env.') and name != '.env.example' or path.suffix in {'.pem', '.key'}):
            print('FAIL: secret file found in product directory; content not read', file=sys.stderr)
            sys.exit(1)
        # This checker contains generic patterns, not actual records or local paths.
        if PATTERN.search(rel.encode()) or PATTERN.search(path.read_bytes() if not path.is_symlink() else os.readlink(path).encode()):
            print('FAIL: publishability rule in product file (name withheld)', file=sys.stderr)
            sys.exit(1)
print('PASS: generic publishability')
