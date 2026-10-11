#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
INCOMING=/srv/migration/current
ENVFILE=$BASE/.env
DUMP="$INCOMING/vestacos_m.sql.gz"
[[ -s "$DUMP" ]] || DUMP="$INCOMING/vesta-db.sql.gz"
[[ -s "$DUMP" ]] || { echo "Vesta dump not found"; exit 2; }

set -a
source "$ENVFILE"
set +a

GOOD_BACKUP="$(find /srv/backups/pre-refresh -type f -name 'vesta-before-refresh.sql.gz' 2>/dev/null | sort | tail -1 || true)"

restore_good_backup() {
  if [[ -n "$GOOD_BACKUP" && -s "$GOOD_BACKUP" ]]; then
    echo "Import failed; restoring previous known-good Vesta DB from backup."
    docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e       "DROP DATABASE IF EXISTS \`vestacos_m\`; CREATE DATABASE \`vestacos_m\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`vestacos_m\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"
    gzip -cd "$GOOD_BACKUP" | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m
    docker start vc-vesta >/dev/null || true
    echo "Rollback completed."
  else
    echo "No known-good Vesta DB backup available for rollback."
  fi
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then restore_good_backup; fi; exit $rc' EXIT

echo "=== New Vesta dump ==="
ls -lh --time-style=long-iso "$DUMP"

echo "=== Stop Vesta app and recreate DB ==="
docker stop vc-vesta >/dev/null || true
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e   "DROP DATABASE IF EXISTS \`vestacos_m\`; CREATE DATABASE \`vestacos_m\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`vestacos_m\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"

echo "=== Import with wp_options zero-ID repair ==="
DUMP_PATH="$DUMP" python3 - <<'PY' | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m
import gzip, os, re, sys
path=os.environ["DUMP_PATH"]
in_opts=False
next_id=900000000000000001
fixed=0
def strip_definer(s):
    return re.sub(r"DEFINER=`[^`]+`@`[^`]+`", "", s)

with gzip.open(path, "rt", encoding="utf-8", errors="surrogateescape") as f:
    for line in f:
        if line.startswith("INSERT INTO `wp_options`"):
            in_opts=True
        if in_opts:
            stripped=line.lstrip()
            if stripped.startswith("(0,"):
                prefix=line[:len(line)-len(stripped)]
                line=prefix+"("+str(next_id)+","+stripped[3:]
                next_id += 1
                fixed += 1
        sys.stdout.write(strip_definer(line))
        if in_opts and line.rstrip().endswith(";"):
            in_opts=False
print(f"-- repaired_wp_options_zero_ids={fixed}", file=sys.stderr)
PY

echo "=== Start Vesta app ==="
docker start vc-vesta >/dev/null
sleep 6

echo "=== Verify DB freshness ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-config.php";
$db=new mysqli(DB_HOST,DB_USER,DB_PASSWORD,DB_NAME);
if($db->connect_errno){fwrite(STDERR,"DB connect failed\n"); exit(2);}
$p=$table_prefix ?? "wp_";
$t=$p."wc_orders";
$q=$db->query("SHOW TABLES LIKE \"".$db->real_escape_string($t)."\"");
if($q && $q->num_rows){
  $q2=$db->query("SELECT COUNT(*) c, MAX(date_created_gmt) m FROM `".$t."`");
  if($q2 && ($r=$q2->fetch_assoc())) echo "hpos_orders=".$r["c"]." latest_hpos_order_gmt=".$r["m"].PHP_EOL;
}
$q=$db->query("SELECT COUNT(*) c, MAX(post_date_gmt) m FROM `".$p."posts` WHERE post_type=\"shop_order\"");
if($q && ($r=$q->fetch_assoc())) echo "legacy_orders=".$r["c"]." latest_legacy_order_gmt=".$r["m"].PHP_EOL;
$q=$db->query("SELECT COUNT(*) c, MAX(post_modified_gmt) m FROM `".$p."posts` WHERE post_type=\"product\"");
if($q && ($r=$q->fetch_assoc())) echo "products=".$r["c"]." latest_product_modified_gmt=".$r["m"].PHP_EOL;
'

echo "=== Smoke ==="
for p in / /wp-login.php /wp-admin/; do
  code="$(curl --max-time 30 -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "vesta-cosmetics.ir $p HTTP=$code"
done

trap - EXIT
echo "VESTA_REPAIRED_IMPORT_OK"
