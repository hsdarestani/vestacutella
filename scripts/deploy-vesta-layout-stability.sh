#!/usr/bin/env bash
# Carefully reserve mobile layout space for known Woodmart carousel and hero.
# Does not disable the carousel or change checkout/product functionality.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
PLUGIN="$BASE/wp-content/mu-plugins/vc-vesta-layout-stability.php"
BACKUP="/srv/backups/vesta-layout-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
status() {
 curl --noproxy '*' -kLsS --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 20 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$1"
}
[[ "$(status /)" == 200 ]] || exit 11
[[ ! -e "$PLUGIN" ]] || { echo "Layout helper already exists";exit 12; }
mkdir -p "$BASE/wp-content/mu-plugins"
modified=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  rm -f "$PLUGIN"
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$rc"
}
trap rollback EXIT
modified=1
cat > "$PLUGIN" <<'PHP'
<?php
/* Plugin Name: VC mobile layout reservation */
if (!defined('ABSPATH')) exit;
add_action('wp_head', function() {
 if (is_admin() || !is_front_page()) return;
 echo '<style id="vc-mobile-layout-reservation">
 @media (max-width:767px){
   #carousel-998 { min-height: 652px; }
   .banner-image > picture:has(> img[src*="IMG_2078.png"]) {
      display:block;
      aspect-ratio:1672 / 941;
   }
 }
 </style>';
}, 99);
PHP
chown 33:33 "$PLUGIN"
chmod 644 "$PLUGIN"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-layout-stability.php
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();'
sleep 2
tmp="$(mktemp)"
curl --noproxy '*' -kLsS --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 35 \
 -o "$tmp" https://vesta-cosmetics.ir/
grep -q 'vc-mobile-layout-reservation' "$tmp" || exit 21
grep -q '#carousel-998' "$tmp" || exit 22
grep -q 'type="image/webp"' "$tmp" || exit 23
rm -f "$tmp"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 s="$(curl --noproxy '*' -kLsS --resolve "$d:443:127.0.0.1" --max-time 22 -o /dev/null -w '%{http_code}' "https://$d/")"
 echo "$d status=$s";[[ "$s" == 200 ]] || exit 24
done
modified=0
trap - EXIT
echo "VESTA_LAYOUT_STABILITY_DEPLOY_OK"
