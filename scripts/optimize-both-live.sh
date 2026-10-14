#!/usr/bin/env bash
# Safe rollout of persistent WordPress object cache to CUTELLA only.
set -euo pipefail
BASE=/srv/vestacutella
CONTENT="$BASE/runtime/cutella/wp-content"
CONFIG="$BASE/runtime/cutella/wp-config.php"
WORK="/srv/backups/cutella-redis-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$WORK"
chmod 700 "$WORK"
status() {
 curl -kLsS --max-time 25 --resolve "cutellashop.ir:443:127.0.0.1" \
 -o /dev/null -w '%{http_code}' "https://cutellashop.ir$1"
}
wp() { docker exec vc-cutella php /tmp/vc-wp-cli.phar --allow-root --path=/var/www/html "$@"; }
echo "=== Cutella Redis rollout preflight ==="
[[ "$(status /)" == 200 ]] || { echo "ABORT: Cutella home unhealthy";exit 31; }
[[ "$(status /wp-login.php)" == 200 ]] || { echo "ABORT: Cutella login unhealthy";exit 32; }
[[ "$(docker exec vc-redis redis-cli ping)" == PONG ]] || { echo "ABORT: Redis unavailable";exit 33; }
[[ -f "$CONFIG" ]] && [[ -d "$CONTENT/plugins" ]]
[[ ! -e "$CONTENT/object-cache.php" ]] || { echo "ABORT: existing object cache, refuse overwrite";exit 34; }
[[ ! -e "$CONTENT/plugins/redis-cache" ]] || { echo "ABORT: existing Redis plugin, refuse overwrite";exit 35; }
if grep -q "WP_REDIS_" "$CONFIG"; then echo "ABORT: existing Redis constants";exit 36;fi

cp -p "$CONFIG" "$WORK/wp-config.before.php"
chmod 600 "$WORK/wp-config.before.php"
echo "backup_dir=$WORK"

curl -fLsS --retry 2 --connect-timeout 12 --max-time 55 \
 https://downloads.wordpress.org/plugin/redis-cache.3.0.0.zip -o "$WORK/redis-cache-3.0.0.zip"
curl -fLsS --retry 2 --connect-timeout 12 --max-time 55 \
 https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o "$WORK/wp-cli.phar"
[[ "$(stat -c %s "$WORK/wp-cli.phar")" -gt 3000000 ]] || { echo "WP-CLI download incomplete";exit 37; }
[[ "$(stat -c %s "$WORK/redis-cache-3.0.0.zip")" -gt 50000 ]] || { echo "Plugin download incomplete";exit 38; }
docker cp "$WORK/wp-cli.phar" vc-cutella:/tmp/vc-wp-cli.phar
docker cp "$WORK/redis-cache-3.0.0.zip" vc-cutella:/tmp/vc-redis-plugin.zip
wp core is-installed
if wp plugin is-active redis-cache; then echo "ABORT: Redis plugin unexpectedly active";exit 39;fi

modified=0
rollback() {
  rc=$?
  trap - EXIT
  if [[ "$modified" == 1 ]]; then
    echo "=== CUTELLA REDIS ROLLBACK rc=$rc ==="
    rm -f "$CONTENT/object-cache.php"
    cat "$WORK/wp-config.before.php" > "$CONFIG"
    wp plugin deactivate redis-cache --quiet || true
    if [[ -d "$CONTENT/plugins/redis-cache" ]]; then rm -rf "$CONTENT/plugins/redis-cache";fi
  fi
  exit "$rc"
}
trap rollback EXIT

CONFIG_PATH="$CONFIG" python3 - <<'PY'
import os
p=os.environ["CONFIG_PATH"]
s=open(p,encoding="utf-8",errors="surrogateescape").read()
defs=(
"define('WP_REDIS_CLIENT', 'predis');\n"
"define('WP_REDIS_HOST', 'redis');\n"
"define('WP_REDIS_PORT', 6379);\n"
"define('WP_REDIS_DATABASE', 0);\n"
"define('WP_REDIS_PREFIX', 'vc_cutella:');\n"
"define('WP_REDIS_TIMEOUT', 0.5);\n"
"define('WP_REDIS_READ_TIMEOUT', 0.5);\n"
"define('WP_REDIS_GRACEFUL', true);\n"
)
marker="/* That's all, stop editing!"
i=s.find(marker)
if i<0:
  marker="require_once ABSPATH . 'wp-settings.php';"
  i=s.find(marker)
if i<0: raise RuntimeError("No safe WP bootstrap insertion marker")
s=s[:i]+defs+"\n"+s[i:]
with open(p,"w",encoding="utf-8",errors="surrogateescape") as f:f.write(s)
PY
modified=1
chown 33:33 "$CONFIG"

wp plugin install /tmp/vc-redis-plugin.zip --activate --quiet
wp redis enable

echo "=== Verify Redis WordPress functionality ==="
docker exec vc-cutella php -r '
  require "/var/www/html/wp-load.php";
  if (!wp_using_ext_object_cache()) { fwrite(STDERR,"external object cache not enabled\n");exit(41); }
  if (!wp_cache_set("vc_test_20261014","connected","vc_rollout",90))exit(42);
  if (wp_cache_get("vc_test_20261014","vc_rollout")!=="connected")exit(43);
  echo "Cutella object cache enabled and roundtrip OK\n";
'
docker exec vc-redis redis-cli -n 0 --scan --pattern 'vc_cutella:*' | head -3 || true
for path in / /shop/ /wp-login.php /cart/ /checkout/ /my-account/;do
 c="$(status "$path")"
 echo "cutella $path code=$c"
 case "$c" in 200|301|302) ;; *) echo "Bad HTTP $c";exit 44;;esac
done
for domain in vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 c="$(curl -kLsS --max-time 25 --resolve "$domain:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$domain/")"
 echo "$domain code=$c"
 [[ "$c" == 200 ]] || exit 45
done
modified=0
trap - EXIT
echo "CUTELLA_REDIS_OBJECT_CACHE_ENABLED"
