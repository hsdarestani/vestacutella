#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== DNS and public reachability ==="
SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
echo "server_ipv4=$SERVER_IP"
for h in cutellashop.ir www.cutellashop.ir; do
  echo "--- $h ---"
  getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true
  getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true
  curl -ksSI --max-time 20 "https://$h/" | grep -Ei '^(HTTP/|server:|cf-ray:|cf-cache-status:|location:|content-type:)' || true
done

echo "=== local Cutella health ==="
for p in / /wp-login.php /wp-admin/; do
  code="$(curl --max-time 30 -ksS --resolve cutellashop.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://cutellashop.ir$p" || true)"
  echo "$p HTTP=$code"
done

echo "=== WordPress environment ==="
docker exec vc-cutella php -r '
require "/var/www/html/wp-config.php";
echo "WP_ENVIRONMENT_TYPE=".(defined("WP_ENVIRONMENT_TYPE")?WP_ENVIRONMENT_TYPE:"<undefined>").PHP_EOL;
echo "DISABLE_WP_CRON=".(defined("DISABLE_WP_CRON")?(DISABLE_WP_CRON?"true":"false"):"<undefined>").PHP_EOL;
echo "DB_NAME=".DB_NAME.PHP_EOL;
echo "DB_HOST=".DB_HOST.PHP_EOL;
' || true
if [[ -f "$BASE/runtime/cutella/wp-content/mu-plugins/00-vestacutella-migration-safety.php" ]]; then
  echo "mail_blocker=present"
else
  echo "mail_blocker=absent"
fi

echo "=== Cutella data freshness ==="
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e "
SELECT CONCAT('legacy_orders=',COUNT(*),' latest=',COALESCE(MAX(post_date_gmt),'')) FROM wp_posts WHERE post_type='shop_order';
SELECT CONCAT('products=',COUNT(*),' latest_modified=',COALESCE(MAX(post_modified_gmt),'')) FROM wp_posts WHERE post_type='product';
SELECT CONCAT('users=',COUNT(*)) FROM wp_users;
" || true
if docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e "SHOW TABLES LIKE 'wp_wc_orders';" | grep -q wp_wc_orders; then
  docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e     "SELECT CONCAT('hpos_orders=',COUNT(*),' latest=',COALESCE(MAX(date_created_gmt),'')) FROM wp_wc_orders;"
else
  echo "hpos_orders_table=absent"
fi

echo "=== certificate ==="
echo | openssl s_client -connect 127.0.0.1:443 -servername cutellashop.ir 2>/dev/null | openssl x509 -noout -subject -issuer -dates || true

echo "CUTELLA_STATUS_OK"
