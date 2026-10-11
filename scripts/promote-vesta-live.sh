#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime
ENVFILE=$BASE/.env
DB_BACKUP_DIR=/srv/backups/pre-vesta-live
CANDIDATE_DB=vestacos_candidate
LIVE_DB=vestacos_m

set -a
source "$ENVFILE"
set +a

ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$DB_BACKUP_DIR"

rollback_db() {
  local backup="$1"
  echo "ROLLBACK: restoring previous Vesta database"
  docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e     "DROP DATABASE IF EXISTS \`$LIVE_DB\`; CREATE DATABASE \`$LIVE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$LIVE_DB\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"
  gzip -cd "$backup" | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$LIVE_DB"
  docker start vc-vesta >/dev/null 2>&1 || true
}

echo "=== DNS ==="
SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
echo "server_ipv4=$SERVER_IP"
for h in vesta-cosmetics.ir www.vesta-cosmetics.ir; do
  echo "$h:"
  getent ahostsv4 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true
  getent ahostsv6 "$h" 2>/dev/null | awk '{print $1}' | sort -u || true
done

echo "=== Verify candidate DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N -e "SELECT CONCAT('tables=',COUNT(*)) FROM information_schema.tables WHERE table_schema='$CANDIDATE_DB';
 SELECT CONCAT('orders=',COUNT(*),' latest=',COALESCE(MAX(post_date_gmt),'')) FROM $CANDIDATE_DB.wp_posts WHERE post_type='shop_order';
 SELECT CONCAT('products=',COUNT(*),' latest=',COALESCE(MAX(post_modified_gmt),'')) FROM $CANDIDATE_DB.wp_posts WHERE post_type='product';"

echo "=== Backup current Vesta DB ==="
BACKUP="$DB_BACKUP_DIR/vesta-before-live-$ts.sql.gz"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers "$LIVE_DB" | gzip -1 > "$BACKUP"

echo "=== Create clean candidate dump ==="
CLEAN="/srv/migration/current/vesta-candidate-clean-$ts.sql.gz"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers "$CANDIDATE_DB" | gzip -1 > "$CLEAN"

echo "=== Promote candidate DB ==="
docker stop vc-vesta >/dev/null || true
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e   "DROP DATABASE IF EXISTS \`$LIVE_DB\`; CREATE DATABASE \`$LIVE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$LIVE_DB\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"
if ! gzip -cd "$CLEAN" | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$LIVE_DB"; then
  rollback_db "$BACKUP"
  exit 31
fi

docker start vc-vesta >/dev/null
sleep 6

echo "=== Local smoke after DB promote ==="
ok=1
for p in / /wp-login.php /wp-admin/; do
  code="$(curl --max-time 30 -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/vesta-smoke-body -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "vesta-cosmetics.ir $p HTTP=$code"
  case "$p:$code" in
    /:200|/wp-login.php:200|/wp-admin/:302|/wp-admin/:200) ;;
    *) ok=0 ;;
  esac
done
if [[ "$ok" != 1 ]]; then
  rollback_db "$BACKUP"
  exit 32
fi

echo "=== Freshness on live DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$LIVE_DB" -N -e "SELECT CONCAT('orders=',COUNT(*),' latest=',COALESCE(MAX(post_date_gmt),'')) FROM wp_posts WHERE post_type='shop_order';
 SELECT CONCAT('products=',COUNT(*),' latest=',COALESCE(MAX(post_modified_gmt),'')) FROM wp_posts WHERE post_type='product';"

echo "=== Productionize only Vesta ==="
WP_FILE="$RUNTIME/vesta/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()
s=re.sub(r"define\(\s*['\"]WP_ENVIRONMENT_TYPE['\"]\s*,\s*['\"][^'\"]+['\"]\s*\)\s*;","define('WP_ENVIRONMENT_TYPE', 'production');",s)
s=re.sub(r"define\(\s*['\"]DISABLE_WP_CRON['\"]\s*,\s*(?:true|false)\s*\)\s*;","define('DISABLE_WP_CRON', false);",s,flags=re.I)
for key in ("WP_DEBUG","WP_DEBUG_DISPLAY","WP_DEBUG_LOG"):
    pat=r"define\(\s*['\"]"+key+r"['\"]\s*,\s*[^;]+\)\s*;"
    repl="define('"+key+"', false);"
    if re.search(pat,s):
        s=re.sub(pat,repl,s)
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
rm -f "$RUNTIME/vesta/wp-content/mu-plugins/00-vestacutella-migration-safety.php"
rm -f "$RUNTIME/vesta/wp-content/debug.log" "$RUNTIME/vesta/wp-content/vc-debug.log"
chown 33:33 "$RUNTIME/vesta/wp-config.php"
docker restart vc-vesta >/dev/null
sleep 5

echo "=== Issue fresh Vesta certificate if DNS points here ==="
ROOT_OK=0
WWW_OK=0
if [[ -n "$SERVER_IP" ]] && getent ahostsv4 vesta-cosmetics.ir 2>/dev/null | awk '{print $1}' | grep -Fxq "$SERVER_IP"; then ROOT_OK=1; fi
if [[ -n "$SERVER_IP" ]] && getent ahostsv4 www.vesta-cosmetics.ir 2>/dev/null | awk '{print $1}' | grep -Fxq "$SERVER_IP"; then WWW_OK=1; fi

if [[ "$ROOT_OK" == 1 ]]; then
  LE="$RUNTIME/letsencrypt"
  mkdir -p "$LE"
  restart_nginx(){ docker start vc-nginx >/dev/null 2>&1 || true; }
  trap restart_nginx EXIT
  docker stop vc-nginx >/dev/null 2>&1 || true

  args=(certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email --cert-name vesta-cosmetics.ir -d vesta-cosmetics.ir)
  if [[ "$WWW_OK" == 1 ]]; then args+=(-d www.vesta-cosmetics.ir); fi

  if docker run --rm --network host -v "$LE:/etc/letsencrypt" certbot/certbot "${args[@]}"; then
    install -m 600 "$LE/live/vesta-cosmetics.ir/privkey.pem" "$RUNTIME/certs/vesta/privkey.pem"
    install -m 644 "$LE/live/vesta-cosmetics.ir/fullchain.pem" "$RUNTIME/certs/vesta/fullchain.pem"
    echo "Fresh Vesta certificate installed."
  else
    echo "WARNING: certificate issuance failed; keeping existing certificate."
  fi
  restart_nginx
  trap - EXIT
  sleep 4
else
  echo "WARNING: root DNS does not yet resolve to this server, skipping fresh certificate."
fi

echo "=== Public smoke ==="
for u in https://vesta-cosmetics.ir/ https://vesta-cosmetics.ir/wp-login.php; do
  code="$(curl --max-time 30 -ksS -o /tmp/vesta-public-body -w '%{http_code}' "$u" || true)"
  echo "$u HTTP=$code"
done
title="$(curl --max-time 30 -ksS https://vesta-cosmetics.ir/ | tr '\n' ' ' | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -c 300 || true)"
echo "title=$title"

echo "=== Intentionally disabled incompatible plugin directories ==="
find "$RUNTIME/vesta/wp-content/plugins" -maxdepth 1 -type d -name '*.disabled-for-migration' -printf '%f\n' | sort || true

echo "VESTA_LIVE_PROMOTION_OK"
