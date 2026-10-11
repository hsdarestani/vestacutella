#!/usr/bin/env bash
set -u
ARCHIVE="$(find /srv/migration -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
echo "=== backup runtime hints ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  echo "--- $d domain.conf PHP lines ---"
  tar -xOzf "$ARCHIVE" "backup/$d/domain.conf" 2>/dev/null | grep -iE 'php|handler|cgi|fpm' | head -n 80 || true
done
echo "--- backup/php entries ---"
tar -tzf "$ARCHIVE" | grep '^backup/php' | head -n 100 || true

echo "=== disabled plugin PHP compatibility ==="
for site in cutella vesta; do
  echo "--- $site ---"
  for p in smsir xcart zhaket-updater; do
    base="/var/www/html/wp-content/plugins/$p.disabled-for-migration"
    echo "plugin=$p"
    docker exec "vc-$site" sh -lc '
      base="$1"
      if [ ! -d "$base" ]; then echo "not_disabled_or_missing"; exit 0; fi
      entry=""
      for candidate in "$base/index.php" "$base/xcart.php" "$base/zhaket-updater.php"; do
        if [ -f "$candidate" ]; then entry="$candidate"; break; fi
      done
      if [ -z "$entry" ]; then entry=$(find "$base" -maxdepth 1 -type f -name "*.php" | head -n1); fi
      echo "entry=$entry"
      php -d display_errors=1 -l "$entry" 2>&1 || true
    ' sh "$base"
  done
done
