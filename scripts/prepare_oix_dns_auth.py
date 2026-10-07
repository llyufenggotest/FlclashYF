import base64
import json
import os
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TARGET=ROOT/"core/mihomo/component/oixdnsauth/private_seed_generated.go"
seed=os.environ.get("OIX_DNS_AUTH_SEED", "").strip()
try: raw=base64.b64decode(seed, validate=True)
except Exception: raise SystemExit("invalid Oix DNS-Auth seed")
if len(raw)!=32: raise SystemExit("invalid Oix DNS-Auth seed")
TARGET.parent.mkdir(parents=True, exist_ok=True)
TARGET.write_text("// Generated private build input. Never commit.\npackage oixdnsauth\n\nfunc init() { BuildSeed = "+json.dumps(seed)+" }\n")
