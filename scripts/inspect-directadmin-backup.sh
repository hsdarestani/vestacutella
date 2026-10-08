#!/usr/bin/env bash
# Inspect the DirectAdmin archive with a single decompression pass.
set -euo pipefail

ARCHIVE="${1:-/srv/migration/backup-Oct-07-2026-2.tar.gz}"
LIST_FILE="/tmp/vestacutella-archive-list.txt"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: backup archive not found: $ARCHIVE"
  exit 2
fi

echo "=== host/capacity ==="
hostname
free -h || true
df -hT / /srv/migration
echo

echo "=== archive ==="
ls -lh "$ARCHIVE"
echo

echo "=== reading archive once ==="
rm -f "$LIST_FILE"
tar -tzf "$ARCHIVE" > "$LIST_FILE"
echo "archive readable: OK"
echo "entries: $(wc -l < "$LIST_FILE")"
echo

echo "=== wordpress configs ==="
grep -E 'wp-config\.php$' "$LIST_FILE" | head -n 100 || true
echo

echo "=== SQL/database candidates ==="
grep -Ei '\.sql(\.gz)?$|(^|/)(mysql|database|backup)/' "$LIST_FILE" | head -n 300 || true
echo

echo "=== Cutella/Vesta relevant paths ==="
grep -Ei 'cutella(shop)?\.ir|vesta-?cosmetics?\.ir|public_html|wp-content' "$LIST_FILE" | head -n 500 || true
echo

echo "=== top-level layout ==="
awk -F/ 'NF { if (NF == 1) print $1; else print $1"/"$2 }' "$LIST_FILE" | sort -u | head -n 300 || true
echo

echo "BACKUP_INSPECTION_OK"
