#!/usr/bin/env bash
set -euo pipefail
OLD=93.95.27.75
for d in cutellashop.ir vesta-cosmetics.ir; do
  echo "=== $d via suspected old origin $OLD ==="
  curl -ksS --max-time 20 --resolve "$d:443:$OLD" -D /tmp/h -o /tmp/b "https://$d/" || true
  head -n 12 /tmp/h || true
  grep -Eio '<title>[^<]{0,200}</title>' /tmp/b | head -1 || true
  echo "bytes=$(wc -c < /tmp/b 2>/dev/null || echo 0)"
done
