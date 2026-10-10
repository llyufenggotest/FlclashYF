#!/usr/bin/env python3
"""YF release gate: selects exactly the five owned release assets and writes
version.json with size/SHA256. Native file names keep the numeric pubspec
version (FlClash-0.9.4-...); the YF identity lives only in the tag."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from urllib.parse import quote

REPOSITORY = 'llyufenggotest/FlclashYF'
TAG_PATTERN = re.compile(r'v(\d+\.\d+\.\d+)-yf\.[1-9]\d*')
SUFFIXES = (
    'android-arm64-v8a.apk',
    'windows-x64.zip',
    'ios-arm64-unsigned.ipa',
    'macos-arm64.dmg',
    'macos-x64.dmg',
)


def required_names(tag):
    match = TAG_PATTERN.fullmatch(tag)
    if match is None:
        raise ValueError(f'Only explicit stable YF tags may publish: {tag}')
    return [f'FlClash-{match[1]}-{suffix}' for suffix in SUFFIXES]


def build_manifest(dist, tag, notes, repository=REPOSITORY):
    if repository != REPOSITORY:
        raise ValueError(f'Refusing foreign repository: {repository}')
    names = required_names(tag)
    assets = []
    for name in names:
        file = dist / name
        if not file.is_file() or file.is_symlink():
            raise ValueError(f'Missing release asset: {name}')
        size = file.stat().st_size
        if size <= 0:
            raise ValueError(f'Empty release asset: {name}')
        with file.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        assets.append({
            'name': name,
            'url': f'https://github.com/{repository}/releases/download/'
                   f'{tag}/{quote(name)}',
            'size': size,
            'sha256': digest,
        })
    return {'tag': tag, 'version': tag[1:], 'notes': notes, 'assets': assets}


def stage(dist, out, tag, notes, repository=REPOSITORY):
    """Copies only the five gated assets into out, plus version.json."""
    manifest = build_manifest(dist, tag, notes, repository)
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        raise ValueError(f'Output directory not empty: {out}')
    for asset in manifest['assets']:
        shutil.copy2(dist / asset['name'], out / asset['name'])
    (out / 'version.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n',
        encoding='utf-8',
    )
    return manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('dist', type=Path)
    parser.add_argument('out', type=Path)
    parser.add_argument('tag')
    parser.add_argument('repository')
    parser.add_argument('notes', type=Path)
    args = parser.parse_args()
    manifest = stage(args.dist, args.out, args.tag,
                     args.notes.read_text(encoding='utf-8'), args.repository)
    print(f'Gated {len(manifest["assets"])} assets for {args.tag}')


if __name__ == '__main__':
    main()
