#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime
INCOMING=/srv/migration/current
BACKUPS=/srv/backups/pre-refresh
ENVFILE=$BASE/.env

CUT_DB="$INCOMING/cutella-db.sql.gz"
VESTA_DB="$INCOMING/vesta-db.sql.gz"
CUT_UPLOADS="$INCOMING/cutella-uploads-2026-10.zip"
VESTA_UPLOADS="$INCOMING/vesta-uploads-2026-10.zip"

[[ -f "$ENVFILE" ]] || { echo "Missing $ENVFILE"; exit 2; }
[[ -s "$CUT_DB" ]] || { echo "Missing $CUT_DB"; exit 3; }
[[ -s "$VESTA_DB" ]] || { echo "Missing $VESTA_DB"; exit 4; }

set -a
source "$ENVFILE"
set +a

ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUPS/$ts"

echo "=== Backing up current Hetzner staging DBs ==="
docker exec vc-db-cutella mariadb-dump -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers vestacos_cutella   | gzip -1 > "$BACKUPS/$ts/cutella-before-refresh.sql.gz"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers vestacos_m   | gzip -1 > "$BACKUPS/$ts/vesta-before-refresh.sql.gz"

echo "=== Stopping staging WordPress containers ==="
docker stop vc-cutella vc-vesta >/dev/null

restore_db() {
  local container="$1" db="$2" user="$3" userpass="$4" rootpass="$5" dump="$6"
  echo "Refreshing $db from $(basename "$dump")"
  docker exec "$container" mariadb -uroot -p"$rootpass" -e     "DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$db\`.* TO '$user'@'%'; FLUSH PRIVILEGES;"
  gzip -cd "$dump"     | sed -E 's/DEFINER=\`[^\`]+\`@\`[^\`]+\`//g'     | docker exec -i "$container" mariadb -uroot -p"$rootpass" "$db"
}

restore_db vc-db-cutella vestacos_cutella vestacos_cutella "$CUTELLA_DB_PASSWORD" "$CUTELLA_DB_ROOT_PASSWORD" "$CUT_DB"
restore_db vc-db-vesta vestacos_m vestacos_m "$VESTA_DB_PASSWORD" "$VESTA_DB_ROOT_PASSWORD" "$VESTA_DB_ROOT_PASSWORD" "$VESTA_DB"

merge_month_uploads() {
  local zip="$1" target="$2" label="$3"
  [[ -s "$zip" ]] || { echo "$label uploads zip not supplied; skipping media refresh."; return 0; }
  local tmp
  tmp="$(mktemp -d)"
  unzip -q "$zip" -d "$tmp"

  local src=""
  if [[ -d "$tmp/10" ]]; then
    src="$tmp/10"
  elif [[ -d "$tmp/2026/10" ]]; then
    src="$tmp/2026/10"
  elif [[ -d "$tmp/uploads/2026/10" ]]; then
    src="$tmp/uploads/2026/10"
  elif [[ -d "$tmp/wp-content/uploads/2026/10" ]]; then
    src="$tmp/wp-content/uploads/2026/10"
  else
    # Accept an archive whose root is the contents of October.
    src="$tmp"
  fi

  mkdir -p "$target/wp-content/uploads/2026/10"
  rsync -a "$src/" "$target/wp-content/uploads/2026/10/"
  chown -R 33:33 "$target/wp-content/uploads/2026/10"
  rm -rf "$tmp"
  echo "$label October uploads merged."
}

merge_month_uploads "$CUT_UPLOADS" "$RUNTIME/cutella" "Cutella"
merge_month_uploads "$VESTA_UPLOADS" "$RUNTIME/vesta" "Vesta"

echo "=== Preserve staging safety ==="
for site in cutella vesta; do
  root="$RUNTIME/$site"
  mkdir -p "$root/wp-content/mu-plugins"
  cat > "$root/wp-content/mu-plugins/00-vestacutella-migration-safety.php" <<'PHP'
<?php
/*
Plugin Name: VestaCutella Migration Safety
Description: Blocks outbound WordPress email on staging.
*/
add_filter('pre_wp_mail', function () { return true; });
PHP
  chown 33:33 "$root/wp-content/mu-plugins/00-vestacutella-migration-safety.php"

  WP_FILE="$root/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()
for key,val in [("WP_ENVIRONMENT_TYPE","'staging'"),("DISABLE_WP_CRON","true")]:
    pat=r"define\(\s*['\"]"+re.escape(key)+r"['\"]\s*,\s*[^;]+\)\s*;"
    repl="define('"+key+"', "+val+");"
    if re.search(pat,s):
        s=re.sub(pat,repl,s)
    else:
        marker="/* That's all, stop editing!"
        idx=s.find(marker)
        s=s[:idx]+repl+"\n"+s[idx:] if idx>=0 else s+"\n"+repl+"\n"
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
  chown 33:33 "$root/wp-config.php"
done

echo "=== Restarting staging ==="
docker start vc-cutella vc-vesta >/dev/null
sleep 5

echo "=== Smoke tests ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  for p in / /wp-login.php /wp-admin/; do
    code=$(curl --max-time 30 -ksS --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d$p" || true)
    echo "$d $p HTTP=$code"
  done
done

echo "CURRENT_DATA_REFRESH_OK"
