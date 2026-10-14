#!/usr/bin/env bash
# Safely apply the short-lived guest-only cache; preserves existing app proxy.
set -euo pipefail
TARGET=/srv/vestacutella/repo/infra/nginx.conf
BACKUP="/srv/backups/nginx-safe-speed-$(date -u +%Y%m%dT%H%M%SZ).conf"
EXPECTED_SHA="308d7945e5a42f152313c4add7d4b523bf0d5e7f10e8097356f56cac5d25928f"
mkdir -p /srv/backups
test -s /tmp/nginx.conf
test -s "$TARGET"
for file in "$TARGET" /tmp/nginx.conf; do
  grep -q 'server_name app.vesta-cosmetics.ir;' "$file"
done
sha="$(sha256sum "$TARGET" | awk '{print $1}')"
if [[ "$sha" != "$EXPECTED_SHA" ]]; then
  echo "ABORT: live nginx config has changed since preflight (safe drift check)"
  exit 38
fi

origin_code() {
  local d="$1" p="$2"
  curl -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$d$p"
}
echo "=== Baseline before change ==="
cutella_before="$(origin_code cutellashop.ir /)"
vesta_before="$(origin_code vesta-cosmetics.ir /)"
app_before="$(origin_code app.vesta-cosmetics.ir /)"
echo "cutella=$cutella_before vesta=$vesta_before app=$app_before"
[[ "$cutella_before" == 200 && "$vesta_before" == 200 ]] || {
  echo "ABORT: store baseline unhealthy"; exit 39;
}
cp -a "$TARGET" "$BACKUP"
echo "Backup: $BACKUP"
changed=0
rollback() {
  rc=$?
  trap - EXIT ERR INT TERM
  if [[ "$changed" == 1 ]]; then
    echo "ROLLBACK config due to failed test: $rc"
    cp -a "$BACKUP" "$TARGET"
    docker exec vc-nginx nginx -t || true
    docker exec vc-nginx nginx -s reload || true
  fi
  exit "$rc"
}
trap rollback EXIT
install -m 644 /tmp/nginx.conf "$TARGET"
changed=1
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload
sleep 2

echo "=== Validate stores and app are unchanged ==="
[[ "$(origin_code cutellashop.ir /)" == "$cutella_before" ]]
[[ "$(origin_code vesta-cosmetics.ir /)" == "$vesta_before" ]]
[[ "$(origin_code app.vesta-cosmetics.ir /)" == "$app_before" ]]

echo "=== Verify the 12s guest cache hits ==="
one="$(mktemp)";two="$(mktemp)";cookie="$(mktemp)";private="$(mktemp)"
for f in "$one" "$two"; do
  curl -kLsS --max-time 20 --resolve cutellashop.ir:443:127.0.0.1 \
    -D "$f" -o /dev/null https://cutellashop.ir/
done
echo "1st response:"; grep -Ei "^(HTTP/|x-vc-guest|cache-control:|expires:)" "$one" || true
echo "2nd response:"; grep -Ei "^(HTTP/|x-vc-guest|cache-control:|expires:)" "$two" || true
grep -Eiq '^x-vc-guest-cache:[[:space:]]*status=HIT' "$two"

curl -kLsS --max-time 20 --resolve cutellashop.ir:443:127.0.0.1 \
  -H 'Cookie: woocommerce_items_in_cart=1' \
  -D "$cookie" -o /dev/null https://cutellashop.ir/
echo "Cookie request: $(grep -i '^x-vc-guest-cache:' "$cookie" || true)"
grep -Eiq '^x-vc-guest-cache:[[:space:]]*status=BYPASS' "$cookie"

for path in /cart/ /checkout/ /my-account/ /wp-login.php /?s=sample; do
  curl -kLsS --max-time 20 --resolve cutellashop.ir:443:127.0.0.1 \
    -D "$private" -o /dev/null "https://cutellashop.ir$path"
  if grep -Eiq '^x-vc-guest-cache:[[:space:]]*status=(HIT|MISS|EXPIRED)' "$private"; then
    echo "FAIL: dynamic path cached: $path"
    exit 40
  fi
done
echo "All private and dynamic paths bypass cache."
rm -f "$one" "$two" "$cookie" "$private"
trap - EXIT ERR INT TERM
changed=0
echo "CUTELLA_SAFE_MICROCACHE_DEPLOY_OK"
