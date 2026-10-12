#!/usr/bin/env bash
set -u

BASE=/srv/vestacutella
VESTA=$BASE/runtime/vesta

echo "=== time ==="; date
echo "=== containers ==="; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

echo "=== Cutella sanity ==="
curl --max-time 15 -ksS --resolve cutellashop.ir:443:127.0.0.1 -o /dev/null -w 'home HTTP=%{http_code} SIZE=%{size_download}\n' https://cutellashop.ir/ || true
curl --max-time 15 -ksS --resolve cutellashop.ir:443:127.0.0.1 -o /dev/null -w 'login HTTP=%{http_code} SIZE=%{size_download}\n' https://cutellashop.ir/wp-login.php || true

echo "=== Enable Vesta debug logging (staging only) ==="
WP_FILE="$VESTA/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,encoding="utf-8",errors="surrogateescape").read()
settings=[
    ("WP_DEBUG","true",False),
    ("WP_DEBUG_DISPLAY","false",False),
    ("WP_DEBUG_LOG","'/var/www/html/wp-content/vc-debug.log'",True),
]
for k,v,is_string in settings:
    pat=r"define\(\s*(['\"])"+re.escape(k)+r"\1\s*,\s*[^;]+\)\s*;"
    repl="define('"+k+"', "+v+");"
    if re.search(pat,s):
        s=re.sub(pat,repl,s,count=1)
    else:
        marker="/* That's all, stop editing!"
        idx=s.find(marker)
        line=repl+"\n"
        s=s[:idx]+line+s[idx:] if idx>=0 else s+"\n"+line
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
chown 33:33 "$VESTA/wp-config.php" 2>/dev/null || true
rm -f "$VESTA/wp-content/vc-debug.log"

echo "=== Vesta PHP ==="
docker exec vc-vesta php -v | head -n 5 || true
docker exec vc-vesta php -r 'echo "memory_limit=".ini_get("memory_limit").PHP_EOL."max_execution_time=".ini_get("max_execution_time").PHP_EOL;' || true

echo "=== Vesta database options ==="
if [[ -f "$BASE/.env" ]]; then
  set -a
  source "$BASE/.env"
  set +a
  tmp=$(mktemp)
  chmod 600 "$tmp"
  {
    echo "[client]"
    echo "user=root"
    echo "password=$VESTA_DB_ROOT_PASSWORD"
  } > "$tmp"
  docker cp "$tmp" vc-db-vesta:/tmp/vc-root.cnf >/dev/null
  rm -f "$tmp"

  PREFIX=$(python3 - <<'PY'
import re
s=open("/srv/vestacutella/runtime/vesta/wp-config.php",encoding="utf-8",errors="ignore").read()
m=re.search(r"\$table_prefix\s*=\s*['\"]([^'\"]+)",s)
print(m.group(1) if m else "wp_")
PY
)
  docker exec vc-db-vesta mariadb --defaults-extra-file=/tmp/vc-root.cnf -N -B vestacos_m -e \
    "SELECT option_name, option_value FROM \`${PREFIX}options\` WHERE option_name IN ('siteurl','home','template','stylesheet') ORDER BY option_name;" || true

  echo "=== Vesta active plugins ==="
  ACTIVE=$(docker exec vc-db-vesta mariadb --defaults-extra-file=/tmp/vc-root.cnf -N -B vestacos_m -e \
    "SELECT option_value FROM \`${PREFIX}options\` WHERE option_name='active_plugins' LIMIT 1;" 2>/dev/null || true)
  printf '%s' "$ACTIVE" | grep -oE '[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]+\.php' | sort -u || true
  docker exec vc-db-vesta rm -f /tmp/vc-root.cnf >/dev/null 2>&1 || true
fi

echo "=== Vesta request ==="
curl --max-time 50 -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -D /tmp/vesta.headers -o /tmp/vesta.body https://vesta-cosmetics.ir/ || true
head -n 30 /tmp/vesta.headers 2>/dev/null || true
echo "body_bytes=$(wc -c < /tmp/vesta.body 2>/dev/null || echo 0)"

echo "=== Vesta debug log ==="
if [[ -f "$VESTA/wp-content/vc-debug.log" ]]; then
  tail -n 200 "$VESTA/wp-content/vc-debug.log"
else
  echo "No WordPress debug log created."
fi

echo "=== Vesta Apache tail ==="
docker logs --tail 120 vc-vesta 2>&1 || true

echo "=== disk ==="; df -h /


echo "=== WordPress DB mapping (non-secret) ==="
for site in cutella vesta; do
  echo "--- $site wp-config ---"
  SITE_PATH="$BASE/runtime/$site/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["SITE_PATH"]
s=open(p,encoding="utf-8",errors="ignore").read()
for k in ("DB_NAME","DB_USER","DB_HOST"):
    m=re.search(r"define\(\s*['\"]"+k+r"['\"]\s*,\s*['\"]([^'\"]+)",s)
    print(k+"="+(m.group(1) if m else "<missing>"))
m=re.search(r"\$table_prefix\s*=\s*['\"]([^'\"]+)",s)
print("TABLE_PREFIX="+(m.group(1) if m else "<missing>"))
PY
done

echo "=== database visibility from WordPress containers ==="
for c in vc-cutella vc-vesta; do
  echo "--- $c ---"
  docker exec "$c" php -r '
    require "/var/www/html/wp-config.php";
    $m = @new mysqli(DB_HOST, DB_USER, DB_PASSWORD, DB_NAME);
    if ($m->connect_errno) { echo "CONNECT_ERROR=".$m->connect_error.PHP_EOL; exit; }
    echo "CONNECTED db=".DB_NAME.PHP_EOL;
    $r=$m->query("SHOW TABLES");
    echo "TABLE_COUNT=".($r ? $r->num_rows : 0).PHP_EOL;
    $prefix=$table_prefix ?? "wp_";
    $q=$m->query("SELECT option_name, option_value FROM `".$prefix."options` WHERE option_name IN (\"home\",\"siteurl\")");
    if ($q) while($row=$q->fetch_assoc()) echo $row["option_name"]."=".$row["option_value"].PHP_EOL;
  ' || true
done

echo "=== SQL dump table samples ==="
for sql in "$BASE/staging/backup/vestacos_cutella.sql" "$BASE/staging/backup/vestacos_m.sql"; do
  echo "--- $sql ---"
  grep -m 15 -E '^CREATE TABLE' "$sql" 2>/dev/null || true
done


echo "=== EMERGENCY_VESTA_MAINTENANCE_FIX ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
if (is_plugin_active("maintenance/maintenance.php")) {
  deactivate_plugins("maintenance/maintenance.php", true);
  echo "maintenance plugin disabled".PHP_EOL;
}
if (function_exists("rocket_clean_domain")) {
  rocket_clean_domain();
  echo "WP Rocket cache cleared".PHP_EOL;
}
' || true
docker restart vc-vesta >/dev/null 2>&1 || true
sleep 4
