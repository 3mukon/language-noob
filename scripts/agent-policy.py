#!/usr/bin/env python3
"""Accident guard for supported agent tools; not a security boundary."""
import json
from pathlib import Path
import re
import sys

PROTECTED = ['AGENTS.md', 'CLAUDE.md', 'docs/architecture.md', 'LICENSE', '.github/workflows/', '.github/CODEOWNERS', '.gitleaks.toml', '.gitleaksignore', '.codex/', '.claude/', 'scripts/', '.git/hooks/']
BYPASS = re.compile(r'--no-verify|\bcore\.hookspath\b|\.git[/\\]hooks|\bgit\b[^\n;&|]*\bcommit\b[^\n;&|]*\s-n(?:\s|$)', re.I)
SECRET = re.compile(r'(?:^|[\s/\\\x22\x27=])(?:\.env(?!\.example(?:$|[\s\x22\x27]))(?:[.\w-]*)|[^\s/\\]+\.(?:pem|key)|auth\.json|credentials(?:\.json)?)(?=$|[\s/\\\x22\x27])', re.I)
MUTATION = re.compile(r'>>?|\b(?:rm|mv|cp|tee|touch|chmod|truncate|install)\b|\bsed\s+[^\n]*-i|write_text|write_bytes|writeFile|open\([^\n]*[\x22\x27][wax]', re.I)

def deny(message):
    print('AGENT_POLICY: '+message, file=sys.stderr)
    raise SystemExit(2)

def protected(path, root, rules):
    target = Path(path)
    if not target.is_absolute():
        target = root/target
    try:
        rel = target.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return False
    return any(rel == rule.rstrip('/') or rule.endswith('/') and rel.startswith(rule) for rule in rules)

def check(event, root, rules=None):
    rules = PROTECTED if rules is None else rules
    name = event.get('tool_name', '')
    args = event.get('tool_input', {})
    if not isinstance(args, dict):
        deny('unsupported tool input; review the hook input format')
    # Inspect only tool arguments; cwd/transcript metadata is not outgoing text.
    for key in ['file_path', 'path']:
        value = args.get(key)
        if isinstance(value, str) and SECRET.search(value):
            deny('secret file access refused; use an example file or injected settings')
    if name in {'Bash', 'exec_command', 'shell_command', 'shell'}:
        command = args.get('command', args.get('cmd'))
        if isinstance(command, list):
            command = ' '.join(command)
        if not isinstance(command, str):
            deny('shell command could not be inspected')
        if BYPASS.search(command):
            deny('hook bypass or hook configuration access refused; use file tools to inspect hooks and the installer to check hook routing')
        if SECRET.search(command):
            deny('secret file access refused')
        if MUTATION.search(command) and any(rule.rstrip('/') in command for rule in rules):
            deny('protected-file shell mutation refused; the maintainer applies approved hard-base changes')
    if name == 'apply_patch':
        patch = args.get('command', args.get('input', args.get('patch')))
        if not isinstance(patch, str):
            deny('patch could not be inspected')
        paths = re.findall(r'^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$', patch, re.M)
        if not paths:
            deny('patch target could not be inspected')
        cwd = Path(event.get('cwd', root))
        for path in paths:
            if SECRET.search(path):
                deny('secret-file patch refused')
            target = Path(path) if Path(path).is_absolute() else cwd/path
            if protected(str(target), root, rules):
                deny('protected-file patch refused; the maintainer applies approved hard-base changes')

def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            deny('malformed hook input')
        check(event, Path(__file__).resolve().parents[1])
    except (ValueError, OSError, TypeError):
        deny('policy input unavailable or malformed')

if __name__ == '__main__':
    main()
