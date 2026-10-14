#!/usr/bin/env bash
# Targeted mobile CLS improvement for Woodmart's async carousels.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
P="$BASE/wp-content/mu-plugins/vc-vesta-layout-stability.php"
BACKUP="/srv/backups/vesta-carousel-cls-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
test -s "$P"
grep -q 'vc-mobile-layout-reservation' "$P"
if grep -q 'vc-owl-loading' "$P";then echo "ABORT: CLS helper already installed"; exit 22;fi
status(){
  curl --noproxy '*' -kLsS --resolve "$1:443:127.0.0.1" --max-time 25 -o /dev/null \
  -w '%{http_code}' "https://$1/"
}
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 [[ "$(status "$host")" == 200 ]] || exit 23
done
cp -p "$P" "$BACKUP/vc-vesta-layout-stability.before.php"
modified=0
rollback(){
 r=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  cp -p "$BACKUP/vc-vesta-layout-stability.before.php" "$P"
  docker restart vc-vesta >/dev/null || true
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$r"
}
trap rollback EXIT
modified=1
cat > "$P" <<'PHP'
<?php
/* Plugin Name: VC Vesta mobile carousel stability */
if(!defined('ABSPATH'))exit;
add_action('wp_head',function(){
 if(is_admin()||!is_front_page())return;
 echo '<style id="vc-mobile-layout-reservation">
 @media(max-width:767px){
   .wd-carousel-container.slider-type-post {min-height:650px}
   .banner-image > picture:has(> img[src*="IMG_2078.png"]) {display:block;aspect-ratio:1672/941}
   html.vc-owl-loading .wd-carousel-container.slider-type-post > .owl-carousel:not(.owl-loaded),
   html.vc-owl-loading .wd-carousel-container.slider-type-product > .owl-carousel:not(.owl-loaded){
    visibility:hidden !important;
   }
 }
 </style>';
 echo '<script id="vc-mobile-carousel-guard">
 (function(){
  if(window.matchMedia && !window.matchMedia("(max-width:767px)").matches)return;
  document.documentElement.classList.add("vc-owl-loading");
  setTimeout(function(){document.documentElement.classList.remove("vc-owl-loading");},7000);
 })();
 </script>';
},10);
PHP
chown 33:33 "$P";chmod 644 "$P"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-layout-stability.php
docker restart vc-vesta >/dev/null
for i in $(seq 1 15);do
 [[ "$(status vesta-cosmetics.ir)" == 200 ]] && break
 sleep 2
done
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; if(function_exists("rocket_clean_home"))rocket_clean_home();'
sleep 2
H="$(mktemp)"
curl --noproxy '*' -kLsS --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 30 \
 https://vesta-cosmetics.ir/ > "$H"
grep -q 'vc-mobile-carousel-guard' "$H" || exit 27
grep -q 'vc-owl-loading' "$H" || exit 28
grep -q 'type="image/webp"' "$H" || exit 29
rm -f "$H"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(status "$host")";echo "$host status=$c";[[ "$c" == 200 ]] || exit 30
done
modified=0
trap - EXIT
echo "VESTA_MOBILE_CAROUSEL_GUARD_OK"
