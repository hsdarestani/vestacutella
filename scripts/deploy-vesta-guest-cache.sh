#!/usr/bin/env bash
# Scope: Vesta anonymous home/shop origin only. Never changes the Cloudflare zone,
# databases, plugins, app.vesta routing, or authenticated WooCommerce requests.
set -euo pipefail
BASE=/srv/vestacutella
LIVE="$BASE/repo/infra/nginx.conf"
SOURCE=/tmp/vc-vesta-guest-nginx.conf
BACKUPS=/srv/backups
[[ -f "$LIVE" && -f "$SOURCE" ]] || { echo "Missing Nginx config"; exit 10; }
docker exec vc-nginx nginx -t >/dev/null
if grep -q '12s anonymous-only Vesta origin microcache' "$LIVE"; then
  echo 'ALREADY_APPLIED: leave the existing production configuration unchanged'
  exit 0
fi
mkdir -p "$BACKUPS"
BACKUP="$BACKUPS/vesta-guest-nginx-$(date -u +%Y%m%dT%H%M%SZ).conf"
cp -p "$LIVE" "$BACKUP"
CANDIDATE=$(mktemp /tmp/vc-vesta-guest-candidate-XXXXXX)
cleanup() { rm -f "$CANDIDATE"; }
applied=0
complete=0
rollback_if_needed() {
  rc=$?
  trap - EXIT
  if [[ "$applied" == 1 && "$complete" != 1 ]]; then
    echo "ROLLBACK after failed Vesta guest-cache verification (exit=$rc)"
    cat "$BACKUP" > "$LIVE"
    docker exec vc-nginx nginx -t
    docker exec vc-nginx nginx -s reload
  fi
  cleanup
  exit "$rc"
}
trap rollback_if_needed EXIT

# Apply only the exact, previously verified Vesta location. The rest of the
# live file (including isolated app.vesta and any unrelated changes) survives.
LIVE_CONFIG="$LIVE" NEW_CONFIG="$SOURCE" OUTPUT_CONFIG="$CANDIDATE" python3 <<'PY'
from pathlib import Path
import os
live=Path(os.environ['LIVE_CONFIG']).read_text()
source=Path(os.environ['NEW_CONFIG']).read_text()
legacy='''    location / {
      proxy_pass http://vesta_backend;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto https;
      proxy_set_header X-Forwarded-Host $host;
    }'''
anchor='    location / {\n      # 12s anonymous-only Vesta origin microcache.'
if live.count(legacy)!=1 or source.count(anchor)!=1:
    raise SystemExit('ABORT: Vesta location differs from validated baseline')
start=source.index(anchor)
end=source.index('\n    }', start)+len('\n    }')
replacement=source[start:end]
if 'proxy_no_cache $vc_skip_guest_cache $http_authorization $upstream_http_set_cookie;' not in replacement:
    raise SystemExit('ABORT: missing private/session safety bypass')
if 'proxy_cache_key "$scheme://$host$request_uri";' not in replacement:
    raise SystemExit('ABORT: missing host-specific cache isolation')
if source.count(replacement)!=1:
    raise SystemExit('ABORT: new Vesta block not unique')
candidate=live.replace(legacy,replacement,1)
if 'server_name app.vesta-cosmetics.ir;' not in candidate or 'server_name cutellashop.ir www.cutellashop.ir;' not in candidate:
    raise SystemExit('ABORT: protected app or Cutella route missing')
Path(os.environ['OUTPUT_CONFIG']).write_text(candidate)
PY

# Validate candidate in an isolated Nginx process BEFORE touching the bind mount.
docker run --rm --network vestacutella-backend \
  -v "$CANDIDATE:/etc/nginx/nginx.conf:ro" \
  -v "$BASE/runtime/certs:/etc/nginx/certs:ro" \
  -v "$BASE/runtime/vesta:/var/www/vesta:ro" \
  -v "$BASE/runtime/cutella:/var/www/cutella:ro" \
  --entrypoint nginx nginx:1.27-alpine -t

cat "$CANDIDATE" > "$LIVE"
applied=1
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload

origin_status() {
  local domain="$1" path="$2"
  curl -kLsS --connect-timeout 6 --max-time 18 --resolve "$domain:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$domain$path"
}
for domain in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(origin_status "$domain" /)
  echo "HEALTH $domain code=$code"
  [[ "$code" == 200 ]] || exit 20
done
for path in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php; do
  code=$(origin_status vesta-cosmetics.ir "$path")
  echo "VESTA $path code=$code"
  case "$code" in 200|301|302) ;; *) exit 21;; esac
done
guest_headers=$(mktemp)
private_headers=$(mktemp)
query_headers=$(mktemp)
trap 'rm -f "$guest_headers" "$private_headers" "$query_headers"; rollback_if_needed' EXIT
curl -kLsS --max-time 18 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' \
  -D "$guest_headers" -o /dev/null https://vesta-cosmetics.ir/
curl -kLsS --max-time 18 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' \
  -H 'Cookie: vesta_cache_safety_probe=1' \
  -D "$private_headers" -o /dev/null https://vesta-cosmetics.ir/
curl -kLsS --max-time 18 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' \
  -D "$query_headers" -o /dev/null 'https://vesta-cosmetics.ir/?vc_safety_probe=1'
grep -qi '^x-vc-guest-route: vesta-public-proxy' "$guest_headers"
grep -qi 'x-vc-guest-cache: .*skip=0' "$guest_headers"
grep -qi 'x-vc-guest-cache: .*skip=1' "$private_headers"
grep -qi 'x-vc-guest-cache: .*skip=1' "$query_headers"
echo "VERIFIED: anonymous home eligible; cookies and query bypass; app and checkout healthy"
complete=1
echo "VESTA_GUEST_ORIGIN_MICROCACHE_DEPLOYED backup=$BACKUP"
