#!/usr/bin/env bash
# Non-invasive Redis integration preflight. Deliberately no load tests.
set -euo pipefail
BASE=/srv/vestacutella
echo "=== REDIS OBJECT CACHE INTEGRATION PREFLIGHT ==="
docker exec vc-redis redis-cli PING
docker exec vc-redis redis-cli INFO memory | grep -E '^(used_memory_human|maxmemory_human|maxmemory_policy):' || true
for site in cutella vesta; do
  echo "--- $site ---"
  wp="/srv/vestacutella/runtime/$site/wp-content"
  test -d "$wp"
  if [[ -e "$wp/object-cache.php" ]]; then
    echo "object-cache.php=EXISTS - will not overwrite"
  else
    echo "object-cache.php=none"
  fi
  if [[ -e "$wp/plugins/redis-cache/redis-cache.php" ]]; then
    echo "redis-cache plugin=EXISTS"
  else
    echo "redis-cache plugin=not-installed"
  fi
  docker exec "vc-$site" sh -c 'command -v wp || echo wpcli_not_present; php -r "echo PHP_VERSION, PHP_EOL;"'
  docker exec "vc-$site" php -r '
    require "/var/www/html/wp-load.php";
    echo "wp_version=".get_bloginfo("version").PHP_EOL;
    echo "wp_using_ext_object_cache=".(wp_using_ext_object_cache()?"yes":"no").PHP_EOL;
    echo "cache_key_salt=".(defined("WP_CACHE_KEY_SALT")?"already-defined":"none").PHP_EOL;
  ' 2>/dev/null || echo "WordPress failed to bootstrap"
  grep -Eq "wp-settings.php" "$BASE/runtime/$site/wp-config.php" && echo "config marker present" || echo "config marker missing"
done
echo "=== DOWNLOAD REACHABILITY (without installation) ==="
curl -ILfsS --max-time 15 -o /dev/null -w 'wordpress_repo_http=%{http_code} bytes=%{size_download}\n' https://downloads.wordpress.org/plugin/redis-cache.3.0.0.zip || true
curl -ILfsS --max-time 15 -o /dev/null -w 'wpcli_http=%{http_code}\n' https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar || true
echo "=== PREFLIGHT SUCCESS ==="
