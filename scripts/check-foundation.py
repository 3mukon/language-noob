#!/usr/bin/env python3
"""Validate the deliberately small, flat knowledge-document schema without dependencies."""
import re
import sys
from pathlib import Path

CORE = {'id', 'type', 'title', 'status', 'visibility', 'date', 'summary', 'scope', 'tags'}
STATUSES = {
    'doc': {'draft', 'current', 'superseded', 'archived'},
    'adr': {'proposed', 'accepted', 'rejected', 'superseded', 'deprecated'},
    'lesson': {'active', 'superseded', 'obsolete'},
    'req': {'draft', 'accepted', 'implemented', 'dropped', 'superseded'},
    'plan': {'draft', 'active', 'done', 'cancelled', 'superseded'},
    'decision': {'proposed', 'accepted', 'rejected', 'superseded'},
    'review': {'open', 'closed'},
    'note': {'active', 'archived'},
}

def fields(text):
    if not text.startswith('---\n') or '\n---\n' not in text[4:]:
        raise ValueError('missing frontmatter')
    metadata = {}
    for line in text.split('---', 2)[1].strip().splitlines():
        key, sep, value = line.partition(':')
        if not sep or key in metadata:
            raise ValueError('invalid or duplicate metadata field')
        metadata[key] = value.strip().strip('"')
    return metadata

def main():
    base = Path(sys.argv[1]).resolve()
    index = (base/'INDEX.md').read_text()
    registered = (base/'conventions.md').read_text().split('## Tags', 1)[1].split('\n## ', 1)[0]
    tags = set(re.findall(r'^\| ([a-z][a-z0-9-]*) \|', registered, re.M))
    seen = set()
    paths = set()
    errors = []
    for path in sorted(base.rglob('*.md')):
        if 'templates' in path.relative_to(base).parts or path.name == 'INDEX.md':
            continue
        rel = path.relative_to(base).as_posix()
        paths.add(rel)
        try:
            text = path.read_text()
            meta = fields(text)
            if not CORE <= meta.keys() or any(not meta[x] for x in CORE):
                raise ValueError('missing document core')
            if meta['id'] in seen:
                raise ValueError('duplicate id')
            seen.add(meta['id'])
            if meta['status'] not in STATUSES.get(meta['type'], set()):
                raise ValueError('invalid type/status')
            if meta['visibility'] not in {'public', 'private'}:
                raise ValueError('invalid visibility')
            if base.name == 'deliberation' and meta['visibility'] != 'private':
                raise ValueError('incorrect private visibility')
            if base.name == 'docs' and meta['visibility'] != 'public':
                raise ValueError('incorrect public visibility')
            if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', meta['date']):
                raise ValueError('invalid date')
            for key in ['scope', 'tags']:
                if not (meta[key].startswith('[') and meta[key].endswith(']')):
                    raise ValueError('lists must use flat brackets')
            used = {s.strip().strip('"\'') for s in meta['tags'][1:-1].split(',') if s.strip()}
            if not used <= tags:
                raise ValueError('unregistered tag')
            if re.search(r'<(?:placeholder|project name|language|module path)>|YYYY-MM-DD', text):
                raise ValueError('unfilled seed')
            if meta['type'] in {'adr','lesson','req','plan','decision','review','note'}:
                template = base/'templates'/(meta['type']+'.md')
                template_text = template.read_text()
                required = re.findall(r'^## (.+)\n\n<!-- Required\b', template_text, re.M)
                for heading in required:
                    if '\n## '+heading+'\n' not in text:
                        raise ValueError('missing required section: '+heading)
            row = f"| [{meta['id']}]({rel}) | {meta['status']} | "
            if meta['type'] == 'lesson':
                row += meta['level']+' | '
            row += f"{meta['title']} | {meta['summary']} |"
            if index.count(row) != 1:
                raise ValueError('index row is missing or stale')
        except (ValueError, KeyError, OSError) as exc:
            errors.append(f'{rel}: {exc}')
    indexed = set(re.findall(r'^\| \[[^]]+\]\(([^)]+)\)', index, re.M))
    if indexed != paths:
        errors.append('INDEX: document inventory differs from indexed paths')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('PASS: knowledge core and index ('+base.name+')')
    return 0

if __name__ == '__main__':
    sys.exit(main())
