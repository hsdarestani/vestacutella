#!/usr/bin/env bash
# Remove unused Slider Revolution JavaScript on anonymous Cutella homepage ONLY.
# Product, cart, checkout, admin and logged-in routes remain unchanged.
set -euo pipefail
BASE=/srv/vestacutella/runtime/cutella
MU="$BASE/wp-content/mu-plugins"
PLUGIN="$MU/vc-cutella-anon-home-no-revslider.php"
BACKUP="/srv/backups/cutella-no-revslider-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP" "$MU";chmod 700 "$BACKUP"
code(){
 curl --noproxy '*' -kLsS --max-time 30 --resolve "$1:443:127.0.0.1" \
 -o /dev/null -w '%{http_code}' "https://$1$2"
}
echo "=== Cutella homepage JS preflight ==="
for domain in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 [[ "$(code "$domain" /)" == 200 ]] || { echo "ABORT unhealthy $domain"; exit 31; }
done
if [[ -e "$PLUGIN" ]];then
 grep -q 'vc-cutella-guest-js' "$PLUGIN" || { echo "ABORT unknown existing plugin";exit 32; }
 echo "Already installed, only browser verification is needed"
 exit 0
fi
html="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 28 --resolve cutellashop.ir:443:127.0.0.1 \
 "https://cutellashop.ir/" -o "$html"
grep -q 'revslider/public/js' "$html" || { echo "ABORT source scripts not in homepage HTML";exit 33; }
grep -q 'cutella-banner' "$html" || { echo "ABORT homepage not using expected custom banner";exit 34; }
rm -f "$html"
if [[ -d "$BASE/wp-content/cache/wp-rocket/cutellashop.ir" ]];then
 mkdir -p "$BACKUP/home-cache"
 find "$BASE/wp-content/cache/wp-rocket/cutellashop.ir" -maxdepth 1 -type f \
 -name 'index*' -exec cp -p '{}' "$BACKUP/home-cache/" \;
fi

modified=0
rollback(){
 ec=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  echo "ROLLBACK Cutella guest-home JS change due to rc=$ec"
  rm -f "$PLUGIN"
  docker exec vc-cutella php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$ec"
}
trap rollback EXIT
modified=1
cat > "$PLUGIN" <<'PHP'
<?php
/**
 * Plugin Name: VC Cutella anonymous homepage JS reduction
 * Description: Do not load two unrelated Revolution Slider scripts on custom Cutella homepage.
 */
if(!defined('ABSPATH'))exit;
if(!function_exists('vc_cutella_guest_js_optout')){
 function vc_cutella_guest_js_optout(){
  if(is_admin() || is_user_logged_in() || !is_front_page())return;
  wp_dequeue_script('tp-tools');
  wp_dequeue_script('sr7');
 }
}
add_action('wp_enqueue_scripts','vc_cutella_guest_js_optout',9999);
add_action('wp_print_scripts','vc_cutella_guest_js_optout',9999);
add_action('wp_print_footer_scripts','vc_cutella_guest_js_optout',0);
PHP
chmod 644 "$PLUGIN";chown 33:33 "$PLUGIN"
docker exec vc-cutella php -l /var/www/html/wp-content/mu-plugins/vc-cutella-anon-home-no-revslider.php
echo "=== Refresh only Cutella homepage ==="
docker exec vc-cutella php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "home_cleaned\n";}'
# Nginx keeps anonymous home for 12s. Give it time to expire/revalidate.
sleep 15
for attempt in 1 2 3;do
 html="$(mktemp)"
 curl --noproxy '*' -kLsS --max-time 30 --resolve cutellashop.ir:443:127.0.0.1 \
  https://cutellashop.ir/ -o "$html"
 if ! grep -Eq '<script[^>]+(tp-tools-js|sr7-js|revslider/public/js/)' "$html";then break;fi
 rm -f "$html";sleep 8
done
if grep -Eq '<script[^>]+(tp-tools-js|sr7-js|revslider/public/js/)' "$html";then
 echo "RevSlider scripts still in Cutella homepage; restore original behavior"
 exit 35
fi
grep -q 'cutella-banner' "$html" || { echo "Custom banner disappeared";exit 36; }
grep -q 'cutella-product-card' "$html" || { echo "Custom product cards disappeared";exit 37; }
rm -f "$html"
for domain in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 c="$(code "$domain" /)"
 echo "$domain homepage=$c";[[ "$c" == 200 ]] || exit 38
done
for route in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 c="$(code cutellashop.ir "$route")";echo "cutella$route http=$c"
 case "$c" in 200|301|302) ;; *) exit 39;;esac
done
trap - EXIT
modified=0
echo "CUTELLA_HOMEPAGE_JS_DEPLOY_OK"
