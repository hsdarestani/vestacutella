#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime
LE=$RUNTIME/letsencrypt
SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org)"

dns_has_server() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u | grep -Fxq "$SERVER_IP"
}

echo "=== verifying DNS ==="
for host in cutellashop.ir www.cutellashop.ir vesta-cosmetics.ir www.vesta-cosmetics.ir; do
  if ! dns_has_server "$host"; then
    echo "ERROR: $host does not resolve to this server yet."
    exit 20
  fi
  echo "$host OK"
done

mkdir -p "$LE"

echo "=== issuing fresh Let's Encrypt certificates ==="
restart_nginx() {
  docker start vc-nginx >/dev/null 2>&1 || true
}
trap restart_nginx EXIT

docker stop vc-nginx >/dev/null 2>&1 || true

docker run --rm --network host \
  -v "$LE:/etc/letsencrypt" \
  certbot/certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email \
  --cert-name cutellashop.ir \
  -d cutellashop.ir -d www.cutellashop.ir

docker run --rm --network host \
  -v "$LE:/etc/letsencrypt" \
  certbot/certbot certonly --standalone --non-interactive --agree-tos \
  --register-unsafely-without-email \
  --cert-name vesta-cosmetics.ir \
  -d vesta-cosmetics.ir -d www.vesta-cosmetics.ir

install -m 600 "$LE/live/cutellashop.ir/privkey.pem" "$RUNTIME/certs/cutella/privkey.pem"
install -m 644 "$LE/live/cutellashop.ir/fullchain.pem" "$RUNTIME/certs/cutella/fullchain.pem"
install -m 600 "$LE/live/vesta-cosmetics.ir/privkey.pem" "$RUNTIME/certs/vesta/privkey.pem"
install -m 644 "$LE/live/vesta-cosmetics.ir/fullchain.pem" "$RUNTIME/certs/vesta/fullchain.pem"

restart_nginx
trap - EXIT
sleep 3

productionize_config() {
  local file="$1"
  WP_FILE="$file" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()

# Staging environment -> production.
s=re.sub(
    r"define\(\s*['\"]WP_ENVIRONMENT_TYPE['\"]\s*,\s*['\"]staging['\"]\s*\)\s*;",
    "define('WP_ENVIRONMENT_TYPE', 'production');",
    s
)

# Re-enable normal WordPress cron. If multiple staging-added definitions exist,
# replace all true values with false to avoid duplicate-constant surprises.
s=re.sub(
    r"define\(\s*['\"]DISABLE_WP_CRON['\"]\s*,\s*true\s*\)\s*;",
    "define('DISABLE_WP_CRON', false);",
    s,
    flags=re.I
)

# Diagnostics must not be displayed or logged in production.
for key,val in (("WP_DEBUG","false"),("WP_DEBUG_DISPLAY","false"),("WP_DEBUG_LOG","false")):
    pat=r"define\(\s*['\"]"+key+r"['\"]\s*,\s*[^;]+\)\s*;"
    repl="define('"+key+"', "+val+");"
    if re.search(pat,s):
        s=re.sub(pat,repl,s)

open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
  chown 33:33 "$file"
}

echo "=== switching WordPress clones from staging safety to production ==="
for site in cutella vesta; do
  root="$RUNTIME/$site"
  rm -f "$root/wp-content/mu-plugins/00-vestacutella-migration-safety.php"
  rm -f "$root/wp-content/vc-debug.log" "$root/wp-content/debug.log"
  productionize_config "$root/wp-config.php"
done

# Known-broken encoded plugins deliberately stay disabled. Re-enabling them
# causes HTTP 500 under the supported PHP/ionCube runtime.
echo "=== intentionally disabled incompatible plugins ==="
find "$RUNTIME/cutella/wp-content/plugins" "$RUNTIME/vesta/wp-content/plugins" \
  -maxdepth 1 -type d -name '*.disabled-for-migration' -print || true

echo "=== restart WordPress/proxy ==="
docker restart vc-cutella vc-vesta >/dev/null
docker restart vc-nginx >/dev/null
sleep 5

echo "=== production smoke tests ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  for p in / /wp-login.php /wp-admin/; do
    code=$(curl --max-time 25 -ksS -o /dev/null -w '%{http_code}' "https://$d$p" || true)
    echo "$d $p HTTP=$code"
  done
done

echo "GO_LIVE_COMPLETED"
