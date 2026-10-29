#!/usr/bin/env python3
import ast
import json
import shutil
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
targets = [root/'scripts', root/'.codex', root/'.claude', root/'Sources'/'LanguageNoob'/'Resources']
if len(sys.argv) > 2:
    targets = [Path(x).resolve() for x in sys.argv[2:]]
for target in targets:
    for path in sorted(target.rglob('*')):
        if not path.is_file():
            continue
        if path.suffix == '.py':
            ast.parse(path.read_text(), filename=path.name)
        elif path.suffix == '.sh':
            subprocess.run(['bash', '-n', str(path)], check=True)
        elif path.suffix == '.json':
            json.loads(path.read_text())
        elif path.suffix == '.js':
            node = shutil.which('node')
            if node:
                subprocess.run([node, '--check', str(path)], check=True)
if len(sys.argv) == 2:
    configured = {'.git', '.gitignore', '.ignore', '.gitleaks.toml', '.gitleaksignore', '.env.example', '.DS_Store', '.github', '.codex', '.claude', 'AGENTS.md', 'CLAUDE.md', 'README.md', 'LICENSE', 'CONTRIBUTING.md', 'docs', 'scripts', 'Package.swift', 'Sources', 'Tests', 'tools', 'dist', '.build'}
    if any(path.name not in configured for path in root.iterdir()):
        print('FAIL: unconfigured product content; add it to the stack layout and application check.', file=sys.stderr)
        sys.exit(1)
print('PASS: shell, Python and JSON syntax')
