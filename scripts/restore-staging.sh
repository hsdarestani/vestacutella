#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${1:-}" ]]; then
  ARCHIVE="$1"
else
  ARCHIVE="$(find /srv/migration -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
fi

[[ -n "${ARCHIVE:-}" ]] || { echo "No .tar.gz backup found in /srv/migration"; exit 2; }
BASE=/srv/vestacutella
REPO=$BASE/repo
STAGING=$BASE/staging
RUNTIME=$BASE/runtime
ENVFILE=$BASE/.env
COMPOSE="$REPO/infra/docker-compose.yml"

[[ -f "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE"; exit 2; }
[[ -f "$COMPOSE" ]] || { echo "Compose file not found: $COMPOSE"; exit 2; }

echo "Using backup: $ARCHIVE"
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
PREVIOUS_SHA="$(cat "$STAGING/.archive-sha256" 2>/dev/null || true)"
if [[ "$ARCHIVE_SHA" != "$PREVIOUS_SHA" ]]; then
  echo "New backup detected; staging/import markers will be refreshed."
  rm -f "$STAGING/.extracted"
  rm -f "$RUNTIME/db-cutella/.imported" "$RUNTIME/db-vesta/.imported" "$RUNTIME/.app-passwords-rotated"
fi

mkdir -p "$STAGING" "$RUNTIME" "$RUNTIME/certs/cutella" "$RUNTIME/certs/vesta"

if [[ ! -f "$STAGING/.extracted" || ! -d "$STAGING/domains/cutellashop.ir/public_html" || ! -d "$STAGING/domains/vesta-cosmetics.ir/public_html" || ! -s "$STAGING/backup/vestacos_cutella.sql" || ! -s "$STAGING/backup/vestacos_m.sql" ]]; then
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
  printf '%s\n' "$ARCHIVE_SHA" > "$STAGING/.archive-sha256"
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

echo "=== syncing WordPress files ==="
mkdir -p "$RUNTIME/cutella" "$RUNTIME/vesta"
rsync -a --delete "$STAGING/domains/cutellashop.ir/public_html/" "$RUNTIME/cutella/"
rsync -a --delete "$STAGING/domains/vesta-cosmetics.ir/public_html/" "$RUNTIME/vesta/"

# The server has limited disk. Once both sites are copied into runtime, the
# extracted duplicate WordPress trees are no longer needed for this restore.
rm -rf "$STAGING/domains"

patch_wp_config "$RUNTIME/cutella/wp-config.php" vestacos_cutella vestacos_cutella "$CUTELLA_DB_PASSWORD" db-cutella
patch_wp_config "$RUNTIME/vesta/wp-config.php" vestacos_m vestacos_m "$VESTA_DB_PASSWORD" db-vesta

echo "=== disabling staging-only plugins blocked by the current ionCube loader ==="
for site in "$RUNTIME/cutella" "$RUNTIME/vesta"; do
  for plugin in zhaket-updater xcart smsir; do
    if [[ -d "$site/wp-content/plugins/$plugin" ]]; then
      rm -rf "$site/wp-content/plugins/$plugin.disabled-for-migration"
      mv "$site/wp-content/plugins/$plugin" "$site/wp-content/plugins/$plugin.disabled-for-migration"
    fi
  done
done

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
echo "=== resetting incomplete database initializations ==="
mkdir -p "$RUNTIME/markers"
if [[ ! -f "$RUNTIME/markers/db-cutella.imported" ]]; then
  docker rm -f vc-db-cutella >/dev/null 2>&1 || true
  rm -rf "$RUNTIME/db-cutella"
fi
if [[ ! -f "$RUNTIME/markers/db-vesta.imported" ]]; then
  docker rm -f vc-db-vesta >/dev/null 2>&1 || true
  rm -rf "$RUNTIME/db-vesta"
fi

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

if [[ ! -f "$RUNTIME/markers/db-cutella.imported" ]]; then
  echo "=== importing Cutella database ==="
  sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$STAGING/backup/vestacos_cutella.sql" \
    | docker exec -i vc-db-cutella mariadb -uvestacos_cutella -p"$CUTELLA_DB_PASSWORD" vestacos_cutella
  touch "$RUNTIME/markers/db-cutella.imported"
fi

if [[ ! -f "$RUNTIME/markers/db-vesta.imported" ]]; then
  echo "=== importing Vesta database ==="
  sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g' "$STAGING/backup/vestacos_m.sql" \
    | docker exec -i vc-db-vesta mariadb -uvestacos_m -p"$VESTA_DB_PASSWORD" vestacos_m
  touch "$RUNTIME/markers/db-vesta.imported"
fi

echo "=== starting WordPress and reverse proxy ==="
docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d --build
# Nginx resolves Docker service names when its configuration is loaded. Recreate it
# after WordPress containers so stale container IPs cannot be cached after a deploy.
docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d --force-recreate nginx
sleep 10

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
