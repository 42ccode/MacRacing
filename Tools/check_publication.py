#!/usr/bin/env python3
"""Read-only publication check of the index and the complete selected Git history.

Heuristic checks complement manual review; passing is not a proof of no secrets.
Reports object IDs and paths, never matched secret values. No network access.
"""
import re
import subprocess
import sys
from pathlib import PurePosixPath


def git(*args):
    return subprocess.check_output(['git', *args])


RULES = {
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    'service token': rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|ASIA[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,}|xox[baprs]-[A-Za-z0-9-]{20,})',
    'credential assignment': rb'(?i)(?:api[_-]?key|client[_-]?secret|access[_-]?token|password)\s*[=:]\s*["\'][^"\'\n]{8,}',
    'credential URL': rb'https?://[^\s/:]+:[^\s/@]+@',
    'local home path': rb'(?:/Users/|/home/)[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\',
    'local host email': rb'[A-Za-z0-9_.+-]+@[A-Za-z0-9_.-]+\.local\b',
}
BLOCKED_PARTS = {'.build', 'dist', 'APEX Lab Data', '.ssh', '.aws', '.azure', '.codex', '.agents', '.venv', '__pycache__'}
BLOCKED_NAMES = {'.DS_Store', '.git-credentials', '.netrc', '.npmrc', 'practice.json', 'latest-session.csv', 'driving-view.png', 'credentials.json', 'secrets.json', 'secrets.yaml', 'secrets.yml'}
BLOCKED_SUFFIXES = {'.pem', '.key', '.p12', '.pfx', '.mobileprovision', '.keychain', '.bundle', '.zip', '.log', '.crash', '.ips'}


def blocked(path):
    p = PurePosixPath(path)
    return bool(set(p.parts) & BLOCKED_PARTS or p.name in BLOCKED_NAMES or
                p.suffix.lower() in BLOCKED_SUFFIXES or
                (p.name.startswith('.env') and p.name != '.env.example') or
                p.name.startswith(('id_rsa', 'id_ed25519')) or
                any(x.endswith(('.app', '.dSYM')) for x in p.parts))


def main():
    refs = sys.argv[1:] or ['HEAD']
    refs = [git('rev-parse', '--verify', ref).decode().strip() for ref in refs]
    errors = set()
    objects = {}
    # Index inspection also catches newly staged files before the next commit.
    for entry in git('ls-files', '--stage', '-z').split(b'\0'):
        if not entry:
            continue
        metadata, path = entry.split(b'\t', 1)
        mode, oid, stage = metadata.split()
        name = path.decode('utf-8', errors='replace')
        if blocked(name):
            errors.add('excluded file in index: ' + name)
        if mode in (b'120000', b'160000') or stage != b'0':
            errors.add('review required for symlink/submodule/conflict: ' + name)
        objects[oid.decode()] = name
    # Inspect every historical tree, including paths removed or renamed later.
    commits = git('rev-list', *refs).decode().splitlines()
    for commit in commits:
        for entry in git('ls-tree', '-r', '-z', commit).split(b'\0'):
            if not entry:
                continue
            metadata, path = entry.split(b'\t', 1)
            mode, kind, oid = metadata.split()
            name = path.decode('utf-8', errors='replace')
            if blocked(name):
                errors.add('excluded file in history: ' + name)
            if mode in (b'120000', b'160000'):
                errors.add('historical symlink/submodule needs review: ' + name)
            objects[oid.decode()] = name
    for row in git('rev-list', '--objects', *refs).decode().splitlines():
        oid, _, path = row.partition(' ')
        objects.setdefault(oid, path)
    # Annotated tags may not appear as objects in rev-list output.
    for ref in refs:
        objects.setdefault(ref, 'selected ref')
    blob_count = 0
    for oid, path in objects.items():
        kind = git('cat-file', '-t', oid).strip()
        if kind not in (b'blob', b'commit', b'tag'):
            continue
        data = git('cat-file', '-p', oid)
        blob_count += kind == b'blob'
        if kind == b'blob' and len(data) >= 50 * 1024 * 1024:
            errors.add('large object requires review: ' + path)
        for label, pattern in RULES.items():
            if re.search(pattern, data):
                errors.add(f'{label}: {kind.decode()} {oid[:10]} {path}')
        if kind in (b'commit', b'tag'):
            for email in re.findall(rb'^(?:author|committer|tagger) .* <([^>]+)>', data, re.M):
                if not email.endswith(b'@users.noreply.github.com'):
                    errors.add(f'non-noreply Git identity: {kind.decode()} {oid[:10]}')
    if errors:
        print('Publication check FAILED (matched values withheld):')
        print('\n'.join(sorted(errors)))
        return 1
    print(f'Publication check passed: {len(commits)} commits, {blob_count} unique blobs, staged files and selected tag metadata.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
