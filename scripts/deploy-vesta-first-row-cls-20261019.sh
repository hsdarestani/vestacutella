#!/usr/bin/env bash
# A/B validated mobile-only reservation for the first new-products row.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
TARGET="$BASE/wp-content/mu-plugins/vc-vesta-new-products-reserve.php"
SOURCE=/tmp/vc-vesta-new-products-reserve.php
BACKUP="/srv/backups/vesta-first-row-reserve-$(date -u +%Y%m%dT%H%M%SZ)"
status(){ curl --noproxy '*' -kLsS --max-time 25 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
test -s "$SOURCE"
test -s "$BASE/wp-content/mu-plugins/vc-vesta-owl-init-mobile.php"
test -s "$BASE/wp-content/mu-plugins/vc-vesta-oct-banner-webp.php"
[[ ! -e "$TARGET" ]] || { echo "ALREADY_EXISTING_PROTECT";exit 0; }
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$d" /)";echo "BEFORE $d $code";[[ "$code" == 200 ]] || exit 11
done
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
active=0;complete=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$active" == 1 && "$complete" != 1 ]];then
  echo "VESTA_ROW_RESERVE_ROLLBACK rc=$rc"
  rm -f "$TARGET"
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$rc"
}
trap rollback EXIT
active=1
install -m 644 "$SOURCE" "$TARGET";chown 33:33 "$TARGET"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-new-products-reserve.php
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "HOME_CACHE_REFRESHED\n";}'
sleep 14
html="$(mktemp)"
visible=0
for attempt in 1 2 3 4 5 6 7 8;do
 curl --noproxy '*' -kLsS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o "$html" https://vesta-cosmetics.ir/
 present=no
 grep -q 'id="vc-vesta-new-products-mobile-reserve"' "$html" && present=yes
 echo "VERIFY_HOME_FRESH attempt=$attempt reserve=$present"
 if [[ "$present" == yes ]];then visible=1;break;fi
 sleep 4
done
[[ "$visible" == 1 ]] || exit 21
grep -q 'vc-oct-banner-mobile-webp' "$html" || exit 22
grep -q 'vc-owl-preinit-layout' "$html" || exit 23
grep -q 'id="nomarg"' "$html" || exit 24
rm -f "$html"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$d" /)";echo "AFTER $d $code";[[ "$code" == 200 ]] || exit 25
done
for route in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 code="$(status vesta-cosmetics.ir "$route")";echo "VESTA_PATH $route $code"
 [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 26
done
complete=1;trap - EXIT
echo "VESTA_MOBILE_FIRST_ROW_STABILITY_DEPLOYED"
