#!/usr/bin/env bash
# Guarded Vesta mobile rendering optimization. No DB, product or plugin modifications.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
MU="$BASE/wp-content/mu-plugins"
PLUGIN="$MU/vc-vesta-optimized-product-render.php"
BACKUP="/srv/backups/vesta-render-visibility-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP" "$MU"
chmod 700 "$BACKUP"
status(){
  curl --noproxy '*' -kLsS --max-time 25 --resolve "$1:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$1$2"
}
echo "=== Vesta mobile visibility safe preflight ==="
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
  [[ "$(status "$d" /)" == 200 ]] || { echo "ABORT site unhealthy: $d";exit 31; }
done
if [[ -e "$PLUGIN" ]]; then
  grep -q 'vc-mobile-product-render' "$PLUGIN" || { echo "ABORT unknown existing plugin"; exit 32; }
  echo "Already installed; preserving existing plugin for independent verification"
  exit 0
fi
[[ -s "$MU/vc-vesta-owl-init-mobile.php" ]] || { echo "ABORT existing safe carousel CSS missing";exit 33; }
[[ -s "$MU/vc-vesta-hero-webp.php" ]] || { echo "ABORT existing optimized image fallback missing";exit 34; }

active=0
rollback(){
  ec=$?
  trap - EXIT
  if [[ "$active" == 1 ]];then
    echo "ROLLBACK Vesta offscreen rendering rc=$ec"
    rm -f "$PLUGIN"
    docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
  fi
  exit "$ec"
}
trap rollback EXIT
active=1
cat > "$PLUGIN" <<'PHP'
<?php
/**
 * Plugin Name: Vesta safe offscreen product rendering
 * Description: Skip rendering mobile carousel product cards only while offscreen.
 */
if (!defined('ABSPATH')) exit;
add_action('wp_head', static function () {
    if (is_admin() || !is_front_page()) return;
    echo '<style id="vc-mobile-product-render">@media(max-width:767px){';
    echo '.wd-carousel-container.slider-type-product .product-wrapper{';
    echo 'content-visibility:auto;contain-intrinsic-size:auto 250px;';
    echo '}</style>';
}, 2);
PHP
chown 33:33 "$PLUGIN";chmod 644 "$PLUGIN"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-optimized-product-render.php
echo "=== Refresh homepage cache only ==="
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "home_cache_cleaned\n";}'
for i in $(seq 1 5);do
 tmp="$(mktemp)"
 curl --noproxy '*' -kLsS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
   https://vesta-cosmetics.ir/ -o "$tmp"
 if grep -q 'id="vc-mobile-product-render"' "$tmp";then break;fi
 rm -f "$tmp";sleep 2
done
grep -q 'id="vc-mobile-product-render"' "$tmp" || { echo "CSS not in HTML";exit 35; }
[[ "$(grep -o 'type="image/webp"' "$tmp" | wc -l)" -ge 9 ]] || { echo "WebP regression"; exit 36; }
grep -q 'vc-owl-preinit-layout' "$tmp" || { echo "Owl CSS regression"; exit 37; }
rm -f "$tmp"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(status "$d" /)"
 echo "$d homepage=$c"
 [[ "$c" == 200 ]] || exit 38
done
for p in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 c="$(status vesta-cosmetics.ir "$p")"
 echo "vesta$p status=$c"
 case "$c" in 200|301|302) ;; *) exit 39;;esac
done
active=0
trap - EXIT
echo "VESTA_RENDER_VISIBILITY_DEPLOY_OK"
