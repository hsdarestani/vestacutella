#!/usr/bin/env bash
# Scoped Vesta Pinterest site preparation, no API/auth changes and no maintenance toggle.
set -Eeuo pipefail
ROOT=/srv/vestacutella/runtime/vesta
SRC=/tmp/vesta-pinterest-sharing.php
DEST="$ROOT/wp-content/mu-plugins/vc-vesta-pinterest-sharing.php"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/srv/backups/vesta-pinterest-sharing-$STAMP"
test -s "$SRC"
test -d "$ROOT/wp-content/mu-plugins"
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
changed=0;previous=0;done_ok=0
rollback() {
  rc=$?
  trap - EXIT
  if [[ "$changed" == 1 && "$done_ok" != 1 ]];then
    echo "PINTEREST_SHARING_ROLLBACK rc=$rc"
    if [[ "$previous" == 1 ]]; then
      cp -p "$BACKUP/vc-vesta-pinterest-sharing.php" "$DEST"
    else
      rm -f "$DEST"
    fi
  fi
  rm -f "$SRC"
  exit "$rc"
}
trap rollback EXIT

for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code="$(curl --noproxy '*' -kLsS --max-time 18 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")"
  echo "PRE_HTTP_$host=$code"
  [[ "$code" == 200 ]] || exit 11
done

if [[ -f "$DEST" ]]; then
  cp -p "$DEST" "$BACKUP/vc-vesta-pinterest-sharing.php"
  previous=1
fi
install -m 644 -o 33 -g 33 "$SRC" "$DEST"
changed=1
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-pinterest-sharing.php

# Test live WP/WooCommerce logic without touching customer sessions or publishing content.
docker exec -i vc-vesta php -d display_errors=0 -r '
error_reporting(E_ERROR|E_PARSE);
require "/var/www/html/wp-load.php";
if(!function_exists("vc_pin_product_context") || !function_exists("wc_get_product")) exit(22);
$ids=get_posts(array("post_type"=>"product","post_status"=>"publish","posts_per_page"=>1,"fields"=>"ids","meta_query"=>array(array("key"=>"_thumbnail_id","compare"=>"EXISTS"))));
if(!$ids)exit(23);
$GLOBALS["wp_query"]=new WP_Query(array("post_type"=>"product","p"=>$ids[0]));
if(!is_product()) exit(24);
ob_start(); vc_pin_product_meta(); $meta=ob_get_clean();
ob_start(); vc_pin_product_share_button(); $button=ob_get_clean();
if(strpos($meta, "og:image")===false || strpos($meta, "og:title")===false) exit(25);
if(strpos($button, "pinterest.com/pin/create/button/")===false || strpos($button, "vesta-cosmetics.ir")===false) exit(26);
echo "WOOCOMMERCE_PIN_META_AND_SHARE_OK product_id=".$ids[0]."\n";
'

for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code="$(curl --noproxy '*' -kLsS --max-time 18 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")"
  echo "POST_HTTP_$host=$code"
  [[ "$code" == 200 ]] || exit 31
done
for path in /shop/ /cart/ /checkout/ /my-account/; do
  code="$(curl --noproxy '*' -kLsS --max-time 18 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "POST_VESTA_$path=$code"
  case "$code" in 200|301|302) ;; *) exit 32;; esac
done
sha256sum "$DEST"
done_ok=1
echo "VESTA_PINTEREST_PRODUCT_SHARING_DEPLOYED=1"
echo "PUBLIC_PINS_PUBLISHED=0"
echo "MAINTENANCE_PLUGIN_UNCHANGED=1"
echo "BACKUP_DIR=$BACKUP"
