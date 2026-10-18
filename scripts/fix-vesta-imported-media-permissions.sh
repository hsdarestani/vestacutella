#!/usr/bin/env bash
# Focused image-directory permission repair after staged Cutella catalog migration.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import
test -d "$BASE"
test -d /srv/backups
umask 077
BACKUP=/srv/backups/vesta-catalog-image-perms-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -m 0700 "$BACKUP"
find "$BASE" -printf '%y %m %P\n' > "$BACKUP/previous-modes.txt"
echo "IMAGE_PREVIOUS_MODES_SAVED $BACKUP"
sample="$(find "$BASE" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' \) -print -quit)"
[[ -n "$sample" ]] || { echo "No media originals to repair" >&2; exit 2; }
rel="$(realpath --relative-to=/srv/vestacutella/runtime/vesta "$sample")"
url="https://vesta-cosmetics.ir/$rel"
echo "MEDIA_BEFORE $(curl -kLsS --max-time 25 -o /dev/null -w '%{http_code} %{content_type}' "$url" || true)"
# The transfer script used umask 077, so new subdirectories were 0700, blocking nginx.
# Only this import tree is touched; older Vesta images and all Cutella files remain unchanged.
find "$BASE" -type d -exec chmod 0755 {} +
find "$BASE" -type f -exec chmod 0644 {} +
echo "MEDIA_AFTER_ORIGIN $(curl -kLsS --max-time 30 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code} %{content_type}' "$url")"
status="$(curl -kLsS --max-time 35 -o /dev/null -w '%{http_code}' "$url")"
echo "MEDIA_AFTER_PUBLIC $status $url"
[[ "$status" == 200 ]] || exit 3
echo "VESTA_IMPORTED_MEDIA_ACCESS_FIXED"
