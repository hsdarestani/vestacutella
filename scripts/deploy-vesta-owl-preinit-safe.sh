#!/usr/bin/env bash
# Only apply a CSS adjustment that was independently validated in cold mobile browsers.
# No Docker, DB, payment, account, WooCommerce or Nginx changes.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
PLUGIN="$BASE/wp-content/mu-plugins/vc-vesta-owl-init-mobile.php"
BACKUP="/srv/backups/vesta-owl-preinit-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
status() {
 curl --noproxy '*' -kLsS --max-time 22 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"
}
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 [[ "$(status "$d" /)" == 200 ]] || { echo "ABORT: baseline unhealthy $d";exit 31; }
done
[[ ! -e "$PLUGIN" ]] || { echo "ABORT: plugin already exists";exit 32; }
test -s "$BASE/wp-content/mu-plugins/vc-vesta-hero-webp.php"
modified=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  rm -f "$PLUGIN"
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
  echo "Automatically reverted experimental carousel CSS"
 fi
 exit "$rc"
}
trap rollback EXIT
modified=1
cat >"$PLUGIN" <<'PHP'
<?php
/* Plugin Name: Vesta pre-init mobile Owl layout fix */
if(!defined('ABSPATH'))exit;
add_action('wp_head',function(){
 if(is_admin()||!is_front_page())return;
 echo '<style id="vc-owl-preinit-layout">@media(max-width:767px){.wd-carousel-container>.owl-carousel.wd-owl:not(.owl-loaded){display:block!important;}}</style>';
},1);
PHP
chown 33:33 "$PLUGIN"
chmod 644 "$PLUGIN"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-owl-init-mobile.php
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "Home cache refreshed\n";}'
sleep 2
for i in $(seq 1 5);do
 html="$(mktemp)"
 curl --noproxy '*' -kLsS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 "https://vesta-cosmetics.ir/" -o "$html"
 if grep -q 'id="vc-owl-preinit-layout"' "$html";then break;fi
 rm -f "$html";sleep 2
done
grep -q 'id="vc-owl-preinit-layout"' "$html" || { echo "Expected early CSS missing, reverting";exit 33; }
imgs="$(grep -o 'type="image/webp"' "$html" | wc -l)"
echo "webp_sources=$imgs"
[[ "$imgs" -ge 9 ]] || { echo "Existing optimized images missing";exit 34; }
rm -f "$html"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(status "$d" /)";echo "$d status=$c";[[ "$c" == 200 ]] || exit 35
done
for p in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 c="$(status vesta-cosmetics.ir "$p")"
 echo "vesta$p status=$c"
 case "$c" in 200|301|302) ;; *) exit 36;;esac
done
trap - EXIT
modified=0
echo "VESTA_CAROUSEL_PREINIT_CSS_DEPLOY_OK"
