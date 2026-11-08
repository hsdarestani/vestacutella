#!/usr/bin/env bash
# Install WooCommerce/Pinterest retail feed generator without altering WordPress content or maintenance mode.
set -Eeuo pipefail
ROOT=/srv/vestacutella/runtime/vesta
BIN_DIR=/usr/local/lib/vesta-pinterest
GEN="$BIN_DIR/vesta-pinterest-feed-generator.php"
RUN=/usr/local/sbin/vesta-pinterest-feed-refresh
CRON=/etc/cron.d/vesta-pinterest-feed
FEED="$ROOT/wp-content/uploads/vesta-pinterest-products.csv"
SOURCE=/tmp/vesta-pinterest-feed-generator.php
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/srv/backups/vesta-pinterest-feed-$STAMP"
test -s "$SOURCE"
test -d "$ROOT/wp-content/uploads"
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 c="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")"
 echo "BEFORE_HTTP_$host=$c"; [[ "$c" == 200 ]] || exit 11
done
mkdir -p "$BACKUP" "$BIN_DIR"
chmod 700 "$BACKUP"
for item in "$GEN" "$RUN" "$CRON" "$FEED"; do
 if [[ -f "$item" ]];then cp -p "$item" "$BACKUP/$(basename "$item")"; fi
done
created=0;complete=0
rollback() {
  rc=$?
  trap - EXIT
  if [[ "$created" == 1 && "$complete" != 1 ]]; then
    echo "PINTEREST_FEED_ROLLBACK rc=$rc"
    for item in "$GEN" "$RUN" "$CRON" "$FEED"; do
      base="$(basename "$item")"
      if [[ -f "$BACKUP/$base" ]]; then
        cp -p "$BACKUP/$base" "$item"
      else
        rm -f "$item"
      fi
    done
  fi
  rm -f "$SOURCE"
  exit "$rc"
}
trap rollback EXIT
install -m 600 "$SOURCE" "$GEN"
created=1
docker exec -i vc-vesta php -l < "$GEN"
cat > "$RUN" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/lock/vesta-pinterest-feed.lock
flock -n 9 || { echo "SKIP_ALREADY_RUNNING"; exit 0; }
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
docker exec -i vc-vesta php -d memory_limit=512M < /usr/local/lib/vesta-pinterest/vesta-pinterest-feed-generator.php
SH
chmod 700 "$RUN"
timeout 480 "$RUN"
# Validate generated file via local filesystem and HTTPS as actual downloadable bytes.
head -1 "$FEED" | grep -q '^id,title,description,link,image_link,price,availability,item_group_id,sale_price,product_type,condition'
count="$(wc -l < "$FEED")"
echo "FEED_LINES=$count"
[[ "$count" -ge 2 ]] || exit 22
header_file="$(mktemp)"
probe_file="$(mktemp)"
trap 'rm -f "$header_file" "$probe_file"' RETURN
curl --noproxy '*' -kLsS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -D "$header_file" -o "$probe_file" \
 https://vesta-cosmetics.ir/wp-content/uploads/vesta-pinterest-products.csv
head -1 "$probe_file" | grep -q '^id,title,description,link,image_link,price,availability,item_group_id,sale_price,product_type,condition'
if grep -Eiq 'maintenance|coming soon|در حال بروزرسانی' "$probe_file"; then echo "FEED_UNEXPECTED_MAINTENANCE"; exit 24; fi
echo "FEED_PUBLIC_DOWNLOAD_OK=1"
rm -f "$header_file" "$probe_file"
cat > "$CRON" <<'CR'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Refreshed 4 times daily, Pinterest ingests feeds daily.
23 0,6,12,18 * * * root /usr/local/sbin/vesta-pinterest-feed-refresh > /var/log/vesta-pinterest-feed.log 2>&1
CR
chmod 644 "$CRON"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 c="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")"
 echo "AFTER_HTTP_$host=$c"; [[ "$c" == 200 ]] || exit 25
done
complete=1
echo "VESTA_PINTEREST_FEED_DEPLOYED=1"
echo "FEED_REFRESH_CRON_INSTALLED=1"
echo "PRODUCTS_NOT_SUBMITTED_TO_PINTEREST=1"
echo "MAINTENANCE_PLUGIN_UNCHANGED=1"
echo "BACKUP=$BACKUP"
