#!/usr/bin/env bash
# Narrow Vesta-only production rollout: MU plugin and a single public landing page.
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
  code=$?
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
  if (vc_vesta_offers_discount_pct(100, 60) > 40) exit(43);
  if (vc_vesta_offers_discount_pct(100, 59) <= 40) exit(44);
  if (vc_vesta_offers_discount_pct(0, 0) != 0) exit(45);
  echo "SHORTCODE_AND_STRICT_THRESHOLD_OK\n";
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
  require "/var/www/html/wp-load.php";
  delete_transient("vc_vesta_offers_over40_v1");
  $p=get_page_by_path("off-40",OBJECT,"page");
  if ($p && function_exists("rocket_clean_post")) rocket_clean_post($p->ID);
'
tmp=$(mktemp)
trap 'rm -f "$tmp";rollback' EXIT
for n in 1 2 3; do
  curl --noproxy '*' -kLsS --max-time 60 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
    'https://vesta-cosmetics.ir/off-40/' -o "$tmp"
  if grep -q 'data-vc-offer="over40"' "$tmp"; then break; fi
  sleep 2
done
grep -q 'data-vc-offer="over40"' "$tmp" || { echo 'Landing page missing shortcode output';exit 61; }
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
