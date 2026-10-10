#!/usr/bin/env bash
set -euo pipefail

ARCHIVE="${1:-/srv/migration/backup-Oct-07-2026-2.tar.gz}"
BASE=/srv/vestacutella
REPO=$BASE/repo
STAGING=$BASE/staging
RUNTIME=$BASE/runtime
ENVFILE=$BASE/.env
COMPOSE="$REPO/infra/docker-compose.yml"

[[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE"; exit 2; }
[[ -f "$COMPOSE" ]] || { echo "Compose file not found: $COMPOSE"; exit 2; }

mkdir -p "$STAGING" "$RUNTIME" "$RUNTIME/certs/cutella" "$RUNTIME/certs/vesta"

if [[ ! -f "$STAGING/.extracted" ]]; then
  echo "=== extracting WordPress sites and required database/certificate files ==="
  rm -rf "$STAGING/domains" "$STAGING/backup"
  tar -xzf "$ARCHIVE" -C "$STAGING" \
    domains/cutellashop.ir/public_html \
    domains/vesta-cosmetics.ir/public_html \
    backup/vestacos_cutella.sql \
    backup/vestacos_m.sql \
    backup/cutellashop.ir/domain.cert \
    backup/cutellashop.ir/domain.key \
    backup/cutellashop.ir/domain.cacert \
    backup/vesta-cosmetics.ir/domain.cert \
    backup/vesta-cosmetics.ir/domain.key \
    backup/vesta-cosmetics.ir/domain.cacert
  touch "$STAGING/.extracted"
fi

for required in \
  "$STAGING/domains/cutellashop.ir/public_html/wp-config.php" \
  "$STAGING/domains/vesta-cosmetics.ir/public_html/wp-config.php" \
  "$STAGING/backup/vestacos_cutella.sql" \
  "$STAGING/backup/vestacos_m.sql"; do
  [[ -s "$required" ]] || { echo "Required file missing: $required"; exit 3; }
done

if [[ ! -f "$ENVFILE" ]]; then
  umask 077
  cat > "$ENVFILE" <<EOF
CUTELLA_DB_PASSWORD=$(openssl rand -hex 24)
CUTELLA_DB_ROOT_PASSWORD=$(openssl rand -hex 24)
VESTA_DB_PASSWORD=$(openssl rand -hex 24)
VESTA_DB_ROOT_PASSWORD=$(openssl rand -hex 24)
EOF
fi
chmod 600 "$ENVFILE"
set -a
source "$ENVFILE"
set +a

echo "=== syncing WordPress files ==="
mkdir -p "$RUNTIME/cutella" "$RUNTIME/vesta"
rsync -a --delete "$STAGING/domains/cutellashop.ir/public_html/" "$RUNTIME/cutella/"
rsync -a --delete "$STAGING/domains/vesta-cosmetics.ir/public_html/" "$RUNTIME/vesta/"

patch_wp_config() {
  local file="$1" dbname="$2" dbuser="$3" dbpass="$4" dbhost="$5"
  WP_FILE="$file" WP_DBNAME="$dbname" WP_DBUSER="$dbuser" WP_DBPASS="$dbpass" WP_DBHOST="$dbhost" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()
vals={
 "DB_NAME":os.environ["WP_DBNAME"],
 "DB_USER":os.environ["WP_DBUSER"],
 "DB_PASSWORD":os.environ["WP_DBPASS"],
 "DB_HOST":os.environ["WP_DBHOST"],
}
for k,v in vals.items():
    pat=r"define\(\s*(['\"])"+re.escape(k)+r"\1\s*,\s*(['\"])[^'\"]*\2\s*\)\s*;"
    repl="define('"+k+"', '"+v.replace("'","\\'")+"');"
    s,n=re.subn(pat,repl,s,count=1)
    if n != 1:
        raise SystemExit("Could not patch "+k+" in "+p)
marker="/* VESTACUTELLA_STAGING_SAFETY */"
if marker not in s:
    addition="""\n/* VESTACUTELLA_STAGING_SAFETY */
define('WP_ENVIRONMENT_TYPE', 'staging');
define('DISABLE_WP_CRON', true);
if (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') { $_SERVER['HTTPS'] = 'on'; }
"""
    stop="/* That's all, stop editing!"
    idx=s.find(stop)
    s = s[:idx] + addition + s[idx:] if idx >= 0 else s + addition
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
}

patch_wp_config "$RUNTIME/cutella/wp-config.php" vestacos_cutella vestacos_cutella "$CUTELLA_DB_PASSWORD" db-cutella
patch_wp_config "$RUNTIME/vesta/wp-config.php" vestacos_m vestacos_m "$VESTA_DB_PASSWORD" db-vesta

echo "=== installing migration safety MU plugin ==="
for site in "$RUNTIME/cutella" "$RUNTIME/vesta"; do
  mkdir -p "$site/wp-content/mu-plugins"
  cat > "$site/wp-content/mu-plugins/00-vestacutella-migration-safety.php" <<'PHP'
<?php
/*
Plugin Name: VestaCutella Migration Safety
Description: Prevents the staging clone from sending mail during migration.
*/
add_filter('pre_wp_mail', function () { return true; });
PHP
done

echo "=== preparing TLS certificates from current DirectAdmin backup ==="
cp "$STAGING/backup/cutellashop.ir/domain.key" "$RUNTIME/certs/cutella/privkey.pem"
cat "$STAGING/backup/cutellashop.ir/domain.cert" "$STAGING/backup/cutellashop.ir/domain.cacert" > "$RUNTIME/certs/cutella/fullchain.pem"
cp "$STAGING/backup/vesta-cosmetics.ir/domain.key" "$RUNTIME/certs/vesta/privkey.pem"
cat "$STAGING/backup/vesta-cosmetics.ir/domain.cert" "$STAGING/backup/vesta-cosmetics.ir/domain.cacert" > "$RUNTIME/certs/vesta/fullchain.pem"
chmod 600 "$RUNTIME/certs/"*/privkey.pem

chown -R 33:33 "$RUNTIME/cutella" "$RUNTIME/vesta"

cd "$REPO"
echo "=== starting databases ==="
docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d db-cutella db-vesta

wait_db() {
  local c="$1"
  for i in $(seq 1 60); do
    if docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null | grep -q healthy; then return 0; fi
    sleep 2
  done
  docker logs --tail 100 "$c" || true
  return 1
}
wait_db vc-db-cutella
wait_db vc-db-vesta

if [[ ! -f "$RUNTIME/db-cutella/.imported" ]]; then
  echo "=== importing Cutella database ==="
  docker exec -i vc-db-cutella mariadb -uvestacos_cutella -p"$CUTELLA_DB_PASSWORD" vestacos_cutella < "$STAGING/backup/vestacos_cutella.sql"
  touch "$RUNTIME/db-cutella/.imported"
fi

if [[ ! -f "$RUNTIME/db-vesta/.imported" ]]; then
  echo "=== importing Vesta database ==="
  docker exec -i vc-db-vesta mariadb -uvestacos_m -p"$VESTA_DB_PASSWORD" vestacos_m < "$STAGING/backup/vestacos_m.sql"
  touch "$RUNTIME/db-vesta/.imported"
fi

echo "=== starting WordPress and reverse proxy ==="
docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d

sleep 8

echo "=== containers ==="
docker compose --env-file "$ENVFILE" -f "$COMPOSE" ps

echo "=== local HTTPS smoke tests (DNS untouched) ==="
for domain in cutellashop.ir vesta-cosmetics.ir; do
  echo "--- $domain ---"
  curl -ksS --resolve "$domain:443:127.0.0.1" -o /tmp/"$domain".html -w "HTTP=%{http_code} SIZE=%{size_download} REDIRECT=%{redirect_url}\n" "https://$domain/" || true
  grep -Eio '<title>[^<]{0,200}</title>' /tmp/"$domain".html | head -n 1 || true
done

echo "=== disk ==="
df -h /
echo "STAGING_RESTORE_FINISHED"
