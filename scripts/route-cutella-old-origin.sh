#!/usr/bin/env bash
set -euo pipefail
TARGET=/srv/vestacutella/repo/infra/nginx.conf
cp "$TARGET" "/srv/backups/nginx-before-cutella-proxy-$(date -u +%Y%m%dT%H%M%SZ).conf" 2>/dev/null || true
install -m 644 /tmp/nginx.conf "$TARGET"
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload
sleep 2
echo "=== public Cutella through Cloudflare ==="
curl -ksS --max-time 20 -D /tmp/h -o /tmp/b https://cutellashop.ir/
head -n 12 /tmp/h
grep -Eio '<title>[^<]{0,200}</title>' /tmp/b | head -1 || true
grep -Ei '^x-powered-by:' /tmp/h || true
echo "bytes=$(wc -c < /tmp/b)"
echo "=== local Vesta smoke ==="
curl -ksS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w 'vesta HTTP=%{http_code}\n' https://vesta-cosmetics.ir/
echo "CUTELLA_OLD_ORIGIN_PROXY_OK"
