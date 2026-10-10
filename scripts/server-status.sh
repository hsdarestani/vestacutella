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
