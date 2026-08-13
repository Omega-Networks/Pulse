#!/usr/bin/env bash
# Regenerate Pulse's vendored NetBox OpenAPI client.
#
# Requires:
#   NETBOX_URL    e.g. https://netbox.example.com
#   NETBOX_TOKEN  v1 token or v2 nbt_… key (no "Token "/"Bearer " prefix)
#   swift-openapi-generator 1.13.0 on PATH, or GENERATOR set to the binary
#
# Never embed a token in this script. Fails closed if the env vars are missing.
set -euo pipefail

if [[ -z "${NETBOX_URL:-}" || -z "${NETBOX_TOKEN:-}" ]]; then
  echo "error: NETBOX_URL and NETBOX_TOKEN must be set in the environment" >&2
  echo "       (v1 token or v2 nbt_ key; do not include the Authorization scheme)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$ROOT/docs/netbox/openapi-generator-config.yaml"
FILTERED="$ROOT/docs/netbox/openapi-filtered.yaml"
OUT="$ROOT/NetBoxAPI/Sources/NetBoxAPI"
RAW="${TMPDIR:-/tmp}/netbox-openapi-raw.yaml"
GENERATOR="${GENERATOR:-swift-openapi-generator}"

if ! command -v "$GENERATOR" >/dev/null 2>&1; then
  echo "error: $GENERATOR not on PATH. Build apple/swift-openapi-generator 1.13.0 and set GENERATOR=" >&2
  exit 1
fi

AUTH_SCHEME="Token"
if [[ "$NETBOX_TOKEN" == nbt_* ]]; then
  AUTH_SCHEME="Bearer"
fi

echo "Fetching schema from ${NETBOX_URL}/api/schema/ …"
curl -fsS \
  -H "Authorization: ${AUTH_SCHEME} ${NETBOX_TOKEN}" \
  -H "Accept: application/vnd.oai.openapi" \
  "${NETBOX_URL%/}/api/schema/" \
  -o "$RAW"

echo "Filtering + generating into $OUT …"
mkdir -p "$OUT"
"$GENERATOR" filter --config "$CONFIG" "$RAW" > "$FILTERED"
# The filter CLI drops components.securitySchemes; restore them so the
# vendored document is generate-ready without the lab.
if ! grep -q '^  securitySchemes:' "$FILTERED"; then
  cat >> "$FILTERED" << 'EOF'
  securitySchemes:
    cookieAuth:
      type: apiKey
      in: cookie
      name: sessionid
    tokenAuth:
      type: apiKey
      in: header
      name: Authorization
      description: '`Token <token>` (v1) or `Bearer <key>.<token>` (v2)'
EOF
fi

"$GENERATOR" generate \
  --config "$CONFIG" \
  --output-directory "$OUT" \
  "$FILTERED"

# Public-repo gate. NetBox may emit the instance URL in `servers:`; another
# instance may embed it in examples. A human review is not the control.
# Rewrite servers to an empty URL, then refuse to finish if the lab host
# still appears in anything this script writes.
python3 - "$FILTERED" "$OUT" "$NETBOX_URL" <<'PY'
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

filtered = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
lab = urlparse(sys.argv[3])
host = (lab.hostname or "").lower()
if not host:
    sys.exit("error: NETBOX_URL has no hostname")

text = filtered.read_text()
normalized = (
    "servers:\n"
    "- url: ''\n"
    "  description: NetBox\n"
)
if re.search(r"^servers:\n", text, re.M):
    text = re.sub(
        r"^servers:\n(?:- url:.*\n(?:  .*\n)*)",
        normalized,
        text,
        count=1,
        flags=re.M,
    )
else:
    text = re.sub(r"^(paths:\n)", normalized + r"\1", text, count=1, flags=re.M)
filtered.write_text(text)

needles = {host}
if lab.netloc:
    needles.add(lab.netloc.lower())
# Full URL minus trailing slash, so https://host/api is also caught.
if lab.geturl():
    needles.add(lab.geturl().rstrip("/").lower())

leaks = []
paths = [filtered, *sorted(out_dir.glob("*.swift"))]
for path in paths:
    body = path.read_text()
    lower = body.lower()
    for needle in needles:
        if needle and needle in lower:
            for i, line in enumerate(body.splitlines(), 1):
                if needle in line.lower():
                    leaks.append(f"{path}:{i}:{line.strip()}")

if leaks:
    print("error: lab instance URL survived vendoring:", file=sys.stderr)
    for leak in leaks:
        print(f"  {leak}", file=sys.stderr)
    sys.exit(1)
PY

echo "Wrote:"
wc -l "$OUT"/*.swift
echo "servers: normalized; no lab host in vendored outputs."
