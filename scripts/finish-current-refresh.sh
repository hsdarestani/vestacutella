#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime
INCOMING=/srv/migration/current
ENVFILE=$BASE/.env

set -a
source "$ENVFILE"
set +a

VESTA_DB="$INCOMING/vestacos_m.sql.gz"
[[ -s "$VESTA_DB" ]] || VESTA_DB="$INCOMING/vesta-db.sql.gz"
[[ -s "$VESTA_DB" ]] || { echo "Vesta DB dump not found"; exit 2; }

echo "=== Restoring current Vesta DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e   "DROP DATABASE IF EXISTS \`vestacos_m\`; CREATE DATABASE \`vestacos_m\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`vestacos_m\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"

gzip -cd "$VESTA_DB"   | sed -E 's/DEFINER=\`[^\`]+\`@\`[^\`]+\`//g'   | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m

merge_zip() {
  local zip="$1"
  local target="$2"
  local label="$3"
  [[ -s "$zip" ]] || { echo "$label uploads missing; skip"; return 0; }

  tmp="$(mktemp -d)"
  unzip -q "$zip" -d "$tmp"
  src="$tmp"

  if [[ -d "$tmp/wp-content/uploads/2026/10" ]]; then
    src="$tmp/wp-content/uploads/2026/10"
  elif [[ -d "$tmp/uploads/2026/10" ]]; then
    src="$tmp/uploads/2026/10"
  elif [[ -d "$tmp/2026/10" ]]; then
    src="$tmp/2026/10"
  elif [[ -d "$tmp/10" ]]; then
    src="$tmp/10"
  fi

  mkdir -p "$target/wp-content/uploads/2026/10"
  rsync -a "$src/" "$target/wp-content/uploads/2026/10/"
  chown -R 33:33 "$target/wp-content/uploads/2026/10"
  rm -rf "$tmp"
  echo "$label uploads merged"
}

echo "=== Merging current October uploads ==="
merge_zip "$INCOMING/cutella-uploads-2026-10.zip" "$RUNTIME/cutella" "Cutella"
merge_zip "$INCOMING/vesta-uploads-2026-10.zip" "$RUNTIME/vesta" "Vesta"

echo "=== Starting WordPress staging ==="
docker start vc-cutella vc-vesta >/dev/null
sleep 6

echo "=== Smoke tests ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  for p in / /wp-login.php /wp-admin/; do
    code="$(curl --max-time 30 -ksS --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d$p" || true)"
    echo "$d $p HTTP=$code"
  done
done

echo "=== DB table counts ==="
docker exec vc-db-cutella mariadb -h127.0.0.1 -uvestacos_cutella -p"$CUTELLA_DB_PASSWORD" vestacos_cutella -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='vestacos_cutella';"
docker exec vc-db-vesta mariadb -h127.0.0.1 -uvestacos_m -p"$VESTA_DB_PASSWORD" vestacos_m -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='vestacos_m';"

echo "CURRENT_REFRESH_FINISHED"
