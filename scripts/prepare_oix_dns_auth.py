"""Materialize private Oix DNS-Auth input without secrets in argv or metadata."""
import base64
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / 'core/mihomo/component/oixdnsauth/private_seed_generated.go'

def materialize(seed: str, target: Path = TARGET):
    seed = seed.strip()
    try:
        raw = base64.b64decode(seed, validate=True)
    except Exception:
        raise ValueError('Missing or invalid Oix DNS-Auth build secret') from None
    if len(raw) != 32:
        raise ValueError('Missing or invalid Oix DNS-Auth build secret')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        '// Generated private build input. Never commit.\n'
        'package oixdnsauth\n\n'
        f'func init() {{ BuildSeed = {json.dumps(seed)} }}\n',
        encoding='utf-8',
    )
    try:
        target.chmod(0o600)
    except OSError:
        pass

if __name__ == '__main__':
    materialize(os.environ.get('OIX_DNS_AUTH_SEED', ''))
    print('Oix DNS-Auth private build input prepared (value omitted)')
