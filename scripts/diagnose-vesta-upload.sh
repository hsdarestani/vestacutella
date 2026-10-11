#!/usr/bin/env bash
set -euo pipefail
D=/srv/migration/current/vestacos_m.sql.gz
[[ -s "$D" ]] || D=/srv/migration/current/vesta-db.sql.gz
echo "FILE:"
ls -lh --time-style=long-iso "$D"
echo "wp_options create/alter snippets:"
gzip -cd "$D" | grep -n -m 8 -E 'CREATE TABLE .wp_options.|ALTER TABLE .wp_options.|INSERT INTO .wp_options.' | cut -c1-400 || true
echo "duplicate option_id counts in dump import candidate:"
tmp=$(mktemp)
gzip -cd "$D" | awk '
  /^INSERT INTO `wp_options`/ {p=1}
  p {print}
  p && /;$/ {p=0}
' > "$tmp"
echo "option INSERT bytes=$(wc -c < "$tmp")"
grep -oE '^\([0-9]+' "$tmp" | sed 's/^(//' | sort -n | uniq -c | sort -nr | head -20 || true
rm -f "$tmp"

echo "around failing ALTER:"
gzip -cd "$D" | sed -n '5441468,5441525p' | cut -c1-500
echo "zero option ids in option inserts:"
gzip -cd "$D" | awk '
  /^INSERT INTO \x60wp_options\x60/ {p=1}
  p {print}
  p && /;$/ {p=0}
' | grep -oE '\(0,' | wc -l || true
