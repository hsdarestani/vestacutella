#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
ENVFILE=$BASE/.env
VESTA=$BASE/runtime/vesta

set -a
source "$ENVFILE"
set +a

echo "=== Vesta runtime ==="
docker exec vc-vesta php -v | head -n 4
docker exec vc-vesta php -r 'echo "memory_limit=".ini_get("memory_limit").PHP_EOL."max_execution_time=".ini_get("max_execution_time").PHP_EOL;'
echo

echo "=== Enable staging debug log for Vesta ==="
WP_FILE="$VESTA/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,encoding="utf-8",errors="surrogateescape").read()
for k,v in [("WP_DEBUG","true"),("WP_DEBUG_DISPLAY","false")]:
    pat=r"define\(\s*(['\"])"+re.escape(k)+r"\1\s*,\s*(true|false)\s*\)\s*;"
    repl="define('"+k+"', "+v+");"
    if re.search(pat,s):
        s=re.sub(pat,repl,s,count=1)
    else:
        marker="/* That's all, stop editing!"
        idx=s.find(marker)
        line="define('"+k+"', "+v+");\n"
        s=s[:idx]+line+s[idx:] if idx>=0 else s+"\n"+line
pat=r"define\(\s*(['\"])WP_DEBUG_LOG\1\s*,[^;]+;"
repl="define('WP_DEBUG_LOG', '/var/www/html/wp-content/vc-debug.log');"
if re.search(pat,s):
    s=re.sub(pat,repl,s,count=1)
else:
    marker="/* That's all, stop editing!"
    idx=s.find(marker)
    line="define('WP_DEBUG_LOG', '/var/www/html/wp-content/vc-debug.log');\n"
    s=s[:idx]+line+s[idx:] if idx>=0 else s+"\n"+line
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
chown 33:33 "$VESTA/wp-config.php"
rm -f "$VESTA/wp-content/vc-debug.log"

echo "=== WordPress options ==="
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

echo
echo "=== Active plugins ==="
ACTIVE=$(docker exec vc-db-vesta mariadb --defaults-extra-file=/tmp/vc-root.cnf -N -B vestacos_m -e \
  "SELECT option_value FROM \`${PREFIX}options\` WHERE option_name='active_plugins' LIMIT 1;" 2>/dev/null || true)
printf '%s' "$ACTIVE" | grep -oE '[A-Za-z0-9_.+-]+/[A-Za-z0-9_.+-]+\.php' | sort -u || true
docker exec vc-db-vesta rm -f /tmp/vc-root.cnf

echo
echo "=== Request Vesta directly through local nginx ==="
set +e
timeout 55 curl -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 \
  -o /tmp/vesta-diagnostic-body -D /tmp/vesta-diagnostic-headers https://vesta-cosmetics.ir/
rc=$?
set -e
echo "curl_exit=$rc"
cat /tmp/vesta-diagnostic-headers 2>/dev/null | head -n 30 || true
echo "body_bytes=$(wc -c < /tmp/vesta-diagnostic-body 2>/dev/null || echo 0)"

echo
echo "=== Vesta WordPress debug log ==="
if [[ -f "$VESTA/wp-content/vc-debug.log" ]]; then
  tail -n 200 "$VESTA/wp-content/vc-debug.log"
else
  echo "No WordPress debug log created."
fi

echo
echo "=== Other recent Vesta logs ==="
find "$VESTA/wp-content" -type f \( -name 'debug.log' -o -name 'error_log' \) -print 2>/dev/null | head -n 30 || true
for f in $(find "$VESTA/wp-content" -type f \( -name 'debug.log' -o -name 'error_log' \) 2>/dev/null | head -n 10); do
  echo "--- $f ---"
  tail -n 80 "$f" 2>/dev/null || true
done

echo
echo "=== Apache tail ==="
docker logs --tail 120 vc-vesta 2>&1 || true
