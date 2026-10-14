#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
TARGET="$BASE/wp-content/mu-plugins/vc-vesta-layout-stability.php"
CURRENT="$(find /srv/backups -maxdepth 1 -type d -name 'vesta-carousel-cls-*' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)"
[[ -n "$CURRENT" ]] || { echo "No matched rollback backup";exit 11;}
SRC="$CURRENT/vc-vesta-layout-stability.before.php"
test -s "$SRC"
grep -q 'vc-mobile-layout-reservation' "$SRC"
if grep -q 'vc-owl-loading' "$SRC";then echo "Backup already contains new CLS guard";exit 12;fi
test -s "$TARGET"
grep -q 'vc-owl-loading' "$TARGET"
echo "Restoring last verified stable layout plugin from $CURRENT"
cp -p "$SRC" "$TARGET"
chown 33:33 "$TARGET"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-layout-stability.php
docker restart vc-vesta >/dev/null
for i in $(seq 1 15);do
 c="$(curl --noproxy '*' -kLsS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://vesta-cosmetics.ir/ || true)"
 [[ "$c" == 200 ]] && break
 sleep 2
done
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();'
tmp="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 https://vesta-cosmetics.ir/ -o "$tmp"
if grep -q 'vc-mobile-carousel-guard' "$tmp";then echo "Guard remains cached";exit 21;fi
grep -q 'type="image/webp"' "$tmp" || exit 22
rm -f "$tmp"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d/")"
 echo "$d status=$code"
 [[ "$code" == 200 ]] || exit 23
done
echo "UNHELPFUL_CLS_GUARD_REVERTED"
