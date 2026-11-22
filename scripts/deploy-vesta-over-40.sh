#!/usr/bin/env bash
# Vesta-only safe all-sale landing + Black Friday badge rollout; original off-40 URL stays live.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
SRC=/tmp/vc-vesta-over-40.php
TARGET="$BASE/wp-content/mu-plugins/vc-vesta-over-40.php"
BACKUP="/srv/backups/vesta-over40-$(date -u +%Y%m%dT%H%M%SZ)"
test -s "$SRC"
test -f "$BASE/wp-config.php"
test -d "$BASE/wp-content/mu-plugins"
docker ps --filter name=vc-vesta --format '{{.Names}} {{.Status}}' | grep -q '^vc-vesta '
for path in / /shop/ /my-account/; do
  status=$(curl --noproxy '*' -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")
  echo "BEFORE $path $status"
  [[ "$status" == 200 ]] || exit 31
done
# Do not activate a graphical badge whose hosted image is missing.
asset_headers=$(curl --noproxy '*' -kLsSI --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
  'https://vesta-cosmetics.ir/wp-content/uploads/2026/11/IMG_3921-1.png')
printf '%s\n' "$asset_headers" | grep -Eqi '^HTTP/[^ ]+ 200' || { echo 'Black Friday PNG not reachable'; exit 32; }
printf '%s\n' "$asset_headers" | grep -Eqi '^content-type: image/' || { echo 'Badge asset is not an image'; exit 33; }
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; if (!function_exists("wc_get_product_ids_on_sale")) exit(31); echo "WOOCOMMERCE_OK\n";'
mkdir -m 0700 -p "$BACKUP"
had_plugin=no
if [[ -e "$TARGET" ]]; then
  cp -p "$TARGET" "$BACKUP/previous.php"
  had_plugin=yes
fi
changed=no
page_created=no
rollback() {
  code=${1:-$?}
  trap - EXIT
  if [[ "$changed" == yes ]]; then
    echo "ROLLBACK over40 rc=$code"
    if [[ "$had_plugin" == yes ]]; then cp -p "$BACKUP/previous.php" "$TARGET"; else rm -f "$TARGET"; fi
    if [[ "$page_created" == yes ]]; then
      docker exec vc-vesta php -r '
        require "/var/www/html/wp-load.php";
        $p = get_page_by_path("off-40", OBJECT, "page");
        if ($p && trim($p->post_content) === "[vc_vesta_over_40]") wp_delete_post($p->ID, true);
      ' || true
    fi
  fi
  exit "$code"
}
trap rollback EXIT

install -m 0644 "$SRC" "$TARGET"
chown 33:33 "$TARGET"
changed=yes
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-over-40.php
docker exec vc-vesta php -r '
  require "/var/www/html/wp-load.php";
  if (!shortcode_exists("vc_vesta_over_40")) exit(42);
  if (vc_vesta_offers_discount_pct(100, 99) <= 0) exit(43);
  if (vc_vesta_offers_discount_pct(100, 100) != 0) exit(44);
  if (vc_vesta_offers_discount_pct(0, 0) != 0) exit(45);
  echo "SHORTCODE_AND_ANY_ACTIVE_SALE_OK\n";
'
page_result=$(docker exec vc-vesta php -r '
  require "/var/www/html/wp-load.php";
  $page = get_page_by_path("off-40", OBJECT, "page");
  if ($page) {
    if (trim($page->post_content) !== "[vc_vesta_over_40]" || $page->post_status !== "publish") {
      fwrite(STDERR, "Conflicting existing page; refusing overwrite\n"); exit(53);
    }
    echo "existing:" . $page->ID; exit;
  }
  $id = wp_insert_post(array(
    "post_type" => "page", "post_status" => "publish",
    "post_name" => "off-40", "post_title" => "تخفیف‌های بالای ۴۰٪",
    "post_content" => "[vc_vesta_over_40]"
  ), true);
  if (is_wp_error($id) || !$id) {
    fwrite(STDERR, "Page creation failed\n"); exit(54);
  }
  echo "created:" . $id;
')
echo "page_result=$page_result"
if [[ "$page_result" == created:* ]]; then page_created=yes; fi

# Clear the landing page cache only; leave shop checkout/session caches untouched.
docker exec vc-vesta php -r '
  $_SERVER["HTTP_HOST"]="vesta-cosmetics.ir";
  $_SERVER["SERVER_NAME"]="vesta-cosmetics.ir";
  $_SERVER["HTTPS"]="on";
  $_SERVER["SERVER_PORT"]="443";
  require "/var/www/html/wp-load.php";
  delete_transient("vc_vesta_offers_over40_v1");
  delete_transient("vc_vesta_offers_anysale_v2");
  $p=get_page_by_path("off-40",OBJECT,"page");
  if ($p && function_exists("rocket_clean_post")) rocket_clean_post($p->ID);
  if (function_exists("rocket_clean_url")) {
    rocket_clean_url("https://vesta-cosmetics.ir/off-40/");
    rocket_clean_url("http://vesta-cosmetics.ir/off-40/");
    rocket_clean_url("https://vesta-cosmetics.ir/");
  }
  if (function_exists("rocket_clean_home")) rocket_clean_home();
'
# Clear only this landing's WP Rocket disk cache if PHP CLI purge left stale HTML.
# Keep unrelated pages, images, cart, checkout, sessions and object cache intact.
for domain in vesta-cosmetics.ir www.vesta-cosmetics.ir; do
  landing_cache="$BASE/wp-content/cache/wp-rocket/$domain/off-40"
  if [[ -d "$landing_cache" ]]; then
    echo "REMOVE_STALE_OFFERS_CACHE $landing_cache"
    find "$landing_cache" -maxdepth 2 -type f -name '*.html*' -delete
  fi
done
tmp=$(mktemp)
trap 'rc=$?; rm -f "$tmp"; rollback "$rc"' EXIT
# Existing page already contains all-sale marker. Wait for this exact version's
# hero and badge styles, rather than stopping on stale cached HTML.
fresh=no
for n in $(seq 1 15); do
  curl --noproxy '*' -kLsS --max-time 60 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
    'https://vesta-cosmetics.ir/off-40/' -o "$tmp"
  if grep -q 'data-vc-offer="all-sale"' "$tmp" && \
     grep -q 'class="vc-offer-hero"' "$tmp" && \
     grep -q 'vc-vesta-bf-number' "$tmp" && \
     grep -q 'id="vesta-bf-badge-css"' "$tmp"; then fresh=yes;break;fi
  echo "STALE_OFFERS_HTML attempt=$n"
  sleep 3
done
[[ "$fresh" == yes ]] || { echo 'New premium design failed to appear on canonical landing';exit 69; }
grep -q 'data-vc-offer="all-sale"' "$tmp" || { echo 'Landing page missing all-sale shortcode output';exit 61; }
grep -q 'id="vesta-bf-badge-css"' "$tmp" || { echo 'Badge CSS not emitted';exit 64; }
grep -q 'id="vesta-bf-badge-js"' "$tmp" || { echo 'Badge JS not emitted';exit 65; }
grep -q 'class="vc-offer-hero"' "$tmp" || { echo 'Premium Black Friday hero missing';exit 66; }
grep -q 'vc-vesta-bf-number' "$tmp" || { echo 'Smaller corrected sale badge CSS missing';exit 67; }
# Homepage hero is the only autoplay interval being changed; product carousels are unchanged.
home_tmp=$(mktemp)
home_ok=no
for n in 1 2 3 4 5 6; do
  curl --noproxy '*' -kLsS --max-time 60 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
    'https://vesta-cosmetics.ir/' -o "$home_tmp"
  if grep -q 'id="vc-vesta-banner-timing"' "$home_tmp" && \
     grep -q 'banners-carousel-wrapper' "$home_tmp"; then home_ok=yes; break; fi
  sleep 3
done
rm -f "$home_tmp"
[[ "$home_ok" == yes ]] || { echo 'Homepage banner timing script missing';exit 68; }
for path in / /shop/ /my-account/; do
  status=$(curl --noproxy '*' -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")
  echo "AFTER $path $status"
  [[ "$status" == 200 ]] || exit 62
done
if docker logs --since 2m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error.*vc-vesta-over-40|Uncaught .*vc-vesta-over-40'; then
  echo "New plugin PHP fatal found";exit 63
fi
rm -f "$tmp"
changed=no
trap - EXIT
echo "VESTA_OVER40_LANDING_LIVE_OK https://vesta-cosmetics.ir/off-40/ backup=$BACKUP"
