#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
TESTROOT=/srv/vestacutella/vesta-php74-test
TESTDB=vestacos_legacytest
TESTC=vc-vesta-php74-test

set -a
source "$ENVFILE"
set +a

cleanup() {
  docker rm -f "$TESTC" >/dev/null 2>&1 || true
  docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$TESTDB\`;" >/dev/null 2>&1 || true
  rm -rf "$TESTROOT" || true
}
trap cleanup EXIT
cleanup

echo "=== clone current DB for isolated compatibility test ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "CREATE DATABASE \`$TESTDB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$TESTDB\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction vestacos_m   | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$TESTDB"

echo "=== make hardlink test tree, break wp-config link, restore legacy plugin folder names only in test ==="
cp -al "$BASE/runtime/vesta" "$TESTROOT"
cp "$TESTROOT/wp-config.php" /tmp/vesta-test-wp-config.php
mv /tmp/vesta-test-wp-config.php "$TESTROOT/wp-config.php"
python3 - "$TESTROOT/wp-config.php" "$TESTDB" <<'PY'
import re,sys
p,db=sys.argv[1],sys.argv[2]
s=open(p,encoding="utf-8",errors="surrogateescape").read()
s=re.sub(r"define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"][^'\"]+['\"]\s*\)\s*;", f"define('DB_NAME', '{db}');", s)
for key,val in [("WP_DEBUG","true"),("WP_DEBUG_DISPLAY","true"),("WP_DEBUG_LOG","true")]:
    pat=r"define\\(\\s*['\\\"]"+key+r"['\\\"]\\s*,\\s*[^;]+\\)\\s*;"
    repl="define('"+key+"', "+val+");"
    if re.search(pat,s):
        s=re.sub(pat,repl,s)
    else:
        marker="/* That's all, stop editing!"
        j=s.find(marker)
        s=s[:j]+repl+"\\n"+s[j:] if j>=0 else s+"\\n"+repl+"\\n"
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
[[ -d "$TESTROOT/wp-content/plugins/smsir.disabled-for-migration" ]] && mv "$TESTROOT/wp-content/plugins/smsir.disabled-for-migration" "$TESTROOT/wp-content/plugins/smsir"
# Keep XCart disabled in this isolated test; restore only SMS.IR first.

NET="$(docker inspect vc-vesta --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
echo "network=$NET"

echo "=== run isolated PHP 7.4 WordPress container with ionCube ==="
docker pull wordpress:php7.4-apache
rm -rf /tmp/ioncube74 /tmp/ioncube74.tar.gz /tmp/ioncube74.ini
curl -fsSL https://downloads.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz -o /tmp/ioncube74.tar.gz
mkdir -p /tmp/ioncube74
tar -xzf /tmp/ioncube74.tar.gz -C /tmp/ioncube74
EXTDIR="$(docker run --rm wordpress:php7.4-apache php -r 'echo ini_get("extension_dir");')"
echo "zend_extension=$EXTDIR/ioncube_loader_lin_7.4.so" > /tmp/ioncube74.ini
echo "extension_dir=$EXTDIR"
docker run -d --name "$TESTC" --network "$NET" -p 127.0.0.1:18080:80 \
  -v "$TESTROOT:/var/www/html" \
  -v "/tmp/ioncube74/ioncube/ioncube_loader_lin_7.4.so:$EXTDIR/ioncube_loader_lin_7.4.so:ro" \
  -v "/tmp/ioncube74.ini:/usr/local/etc/php/conf.d/00-ioncube.ini:ro" \
  wordpress:php7.4-apache >/dev/null
sleep 12
docker exec "$TESTC" php -v
docker exec "$TESTC" php -m | grep -i ionCube || true

echo "=== test My Account legacy behavior ==="
curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -D /tmp/t.h -o /tmp/t.b http://127.0.0.1:18080/my-account/ || true
head -n 12 /tmp/t.h || true
echo "bytes=$(wc -c < /tmp/t.b 2>/dev/null || echo 0)"
echo "BODY_START:"
head -c 1200 /tmp/t.b | tr '\n' ' '; echo
grep -Eio 'smsir-login-app-1|ورود با رمز یک.?بار مصرف|شماره تلفن یا ایمیل|SMS.IR|otp|critical error|خطای مهم' /tmp/t.b | sort -u | head -60 || true

echo "=== smoke isolated legacy-compatible site ==="
for p in / /shop/ /my-account/; do
  curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -o /dev/null -w "$p code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n" "http://127.0.0.1:18080$p" || true
done

echo "=== isolated WordPress debug log ==="
tail -n 220 "$TESTROOT/wp-content/debug.log" 2>/dev/null || true
echo "=== isolated container logs ==="
docker logs --tail 220 "$TESTC" 2>&1 || true

echo "PHP74_COMPAT_TEST_DONE"
