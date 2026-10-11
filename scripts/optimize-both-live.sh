#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
REPO=$BASE/repo
ENVFILE=$BASE/.env
COMPOSE=$REPO/infra/docker-compose.yml
BACKUP=/srv/backups/live-speed
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP/$ts"

set -a
source "$ENVFILE"
set +a

echo "=== backup current proxy config ==="
cp "$REPO/infra/nginx.conf" "$BACKUP/$ts/nginx.conf"
cp "$REPO/infra/docker-compose.yml" "$BACKUP/$ts/docker-compose.yml"

echo "=== clean obsolete migration working copies; original uploaded archive stays ==="
rm -rf "$BASE/staging/domains" "$BASE/staging/backup"
rm -f "$BASE/staging/.extracted"
rm -f /srv/migration/current/vesta-candidate-clean-*.sql.gz 2>/dev/null || true
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS vestacos_candidate;" || true

echo "=== tune live MariaDB memory online ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "
SET GLOBAL innodb_buffer_pool_size=402653184;
SET GLOBAL tmp_table_size=33554432;
SET GLOBAL max_heap_table_size=33554432;
"
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" -e "
SET GLOBAL innodb_buffer_pool_size=201326592;
SET GLOBAL tmp_table_size=33554432;
SET GLOBAL max_heap_table_size=33554432;
"

cleanup_wp_db() {
  local container="$1" rootpass="$2" db="$3"
  echo "--- cleanup $db ---"
  docker exec "$container" mariadb -uroot -p"$rootpass" "$db" -e "
    DELETE v,t
      FROM wp_options t
      LEFT JOIN wp_options v
        ON v.option_name=CONCAT('_transient_',SUBSTRING(t.option_name,20))
     WHERE t.option_name LIKE '\\_transient\\_timeout\\_%'
       AND CAST(t.option_value AS UNSIGNED) > 0
       AND CAST(t.option_value AS UNSIGNED) < UNIX_TIMESTAMP();

    DELETE v,t
      FROM wp_options t
      LEFT JOIN wp_options v
        ON v.option_name=CONCAT('_site_transient_',SUBSTRING(t.option_name,25))
     WHERE t.option_name LIKE '\\_site\\_transient\\_timeout\\_%'
       AND CAST(t.option_value AS UNSIGNED) > 0
       AND CAST(t.option_value AS UNSIGNED) < UNIX_TIMESTAMP();

    DELETE FROM wp_woocommerce_sessions WHERE session_expiry < UNIX_TIMESTAMP();

    ANALYZE TABLE wp_options, wp_postmeta, wp_posts;
  " || true
}

cleanup_wp_db vc-db-vesta "$VESTA_DB_ROOT_PASSWORD" vestacos_m
cleanup_wp_db vc-db-cutella "$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella

echo "=== install optimized nginx/compose ==="
install -m 644 /tmp/nginx.conf "$REPO/infra/nginx.conf"
install -m 644 /tmp/docker-compose.yml "$REPO/infra/docker-compose.yml"

echo "=== recreate only nginx with direct static mounts ==="
cd "$REPO/infra"
docker compose --env-file "$ENVFILE" up -d --no-deps --force-recreate nginx
sleep 5
docker exec vc-nginx nginx -t

echo "=== smoke both sites ==="
for d in vesta-cosmetics.ir cutellashop.ir; do
  for p in / /wp-login.php; do
    code="$(curl --max-time 30 -ksS -o /dev/null -w '%{http_code}' "https://$d$p" || true)"
    echo "$d$p HTTP=$code"
    [[ "$code" == "200" ]] || exit 31
  done
done

echo "=== verify static is served with long cache ==="
for d in vesta-cosmetics.ir cutellashop.ir; do
  asset="$(curl -ksS "https://$d/" | grep -Eo "https://$d/[^\"' ]+\.(css|js)(\?[^\"' ]*)?" | head -1 || true)"
  echo "$d asset=$asset"
  if [[ -n "$asset" ]]; then
    curl -ksSI "$asset" | grep -Ei '^(HTTP/|cache-control:|expires:|server:)' || true
  fi
done

echo "=== resulting DB tuning ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N -e "
SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','tmp_table_size','max_heap_table_size');
"
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" -N -e "
SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','tmp_table_size','max_heap_table_size');
"

echo "=== disk after cleanup ==="
df -h /
docker image prune -f >/dev/null 2>&1 || true
df -h /

echo "LIVE_SPEED_OPTIMIZATION_OK"
