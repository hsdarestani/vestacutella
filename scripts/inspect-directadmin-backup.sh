#!/usr/bin/env bash
# Trigger server inspection after workflow installation
set -euo pipefail

ARCHIVE="${1:-/srv/migration/backup-Oct-07-2026-2.tar.gz}"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: backup archive not found: $ARCHIVE"
  exit 2
fi

echo "=== host ==="
hostname
uname -a
echo

echo "=== memory ==="
free -h || true
echo

echo "=== disks ==="
df -hT
echo

echo "=== archive ==="
ls -lh "$ARCHIVE"
echo

echo "=== gzip integrity ==="
gzip -t "$ARCHIVE"
echo "gzip integrity: OK"
echo

echo "=== relevant archive paths ==="
# DirectAdmin backup layouts vary. Print likely domain, WordPress and SQL paths only.
tar -tzf "$ARCHIVE" | grep -Ei   '(^|/)(cutella(shop)?\.ir|vesta-?cosmetics?\.ir|public_html|wp-config\.php|wp-content|backup/.*\.sql|.*\.sql(\.gz)?$)'   | head -n 500 || true
echo

echo "=== wordpress configs ==="
tar -tzf "$ARCHIVE" | grep -E 'wp-config\.php$' | head -n 50 || true
echo

echo "=== SQL-like files ==="
tar -tzf "$ARCHIVE" | grep -Ei '\.sql(\.gz)?$|mysql|database' | head -n 200 || true
echo

echo "=== top-level archive layout ==="
tar -tzf "$ARCHIVE" | awk -F/ 'NF {print $1"/"$2}' | sort -u | head -n 200 || true
