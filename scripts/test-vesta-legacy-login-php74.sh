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
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
[[ -d "$TESTROOT/wp-content/plugins/smsir.disabled-for-migration" ]] && mv "$TESTROOT/wp-content/plugins/smsir.disabled-for-migration" "$TESTROOT/wp-content/plugins/smsir"
[[ -d "$TESTROOT/wp-content/plugins/xcart.disabled-for-migration" ]] && mv "$TESTROOT/wp-content/plugins/xcart.disabled-for-migration" "$TESTROOT/wp-content/plugins/xcart"

NET="$(docker inspect vc-vesta --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
echo "network=$NET"

echo "=== run isolated PHP 7.4 WordPress container ==="
docker pull wordpress:php7.4-apache
docker run -d --name "$TESTC" --network "$NET" -p 127.0.0.1:18080:80   -v "$TESTROOT:/var/www/html" wordpress:php7.4-apache >/dev/null
sleep 12

echo "=== test My Account legacy behavior ==="
curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -D /tmp/t.h -o /tmp/t.b http://127.0.0.1:18080/my-account/ || true
head -n 12 /tmp/t.h || true
echo "bytes=$(wc -c < /tmp/t.b 2>/dev/null || echo 0)"
grep -Eio 'smsir-login-app-1|ورود با رمز یک.?بار مصرف|شماره تلفن یا ایمیل|SMS.IR|otp' /tmp/t.b | sort -u | head -60 || true

echo "=== smoke isolated legacy-compatible site ==="
for p in / /shop/ /my-account/; do
  curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -o /dev/null -w "$p code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n" "http://127.0.0.1:18080$p" || true
done

echo "=== isolated container logs ==="
docker logs --tail 160 "$TESTC" 2>&1 || true

echo "PHP74_COMPAT_TEST_DONE"
