#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
stage=${1:?staging folder required}
base=/srv/vestacutella/runtime/vesta/wp-content
otp="$base/plugins/vesta-sms-login/vesta-sms-login.php"
mu="$base/mu-plugins/vesta-channel-customers.php"
backup="/srv/backups/vesta-channel-accounts-$(date -u +%Y%m%dT%H%M%SZ)"
exec 9>/run/lock/vesta-channel-accounts-deploy.lock
flock -n 9 || exit 10
mkdir -p -m 0700 "$backup"
test -s "$otp"
test ! -f "$mu"  # A subsequent deployment must explicitly review the existing version.
cp -p "$otp" "$backup/vesta-sms-login.php"
# Keep a private snapshot for audit/recovery; do not restore users or order tables wholesale.
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick "$MARIADB_DATABASE" wp_users wp_usermeta wp_postmeta wp_options' | gzip > "$backup/accounts-before.sql.gz"
gzip -t "$backup/accounts-before.sql.gz"
echo "CUSTOMER_BACKUP_VERIFIED=$backup"
expected=$(cat "$stage/otp-before.sha256")
actual=$(sha256sum "$otp" | cut -d' ' -f1)
[[ "$actual" = "$expected" ]] || { echo OTP_SOURCE_DRIFT_ABORT_NO_CHANGES=yes; exit 20; }
sha256sum "$base/mu-plugins/vesta-accounting-policy.php" "$base/mu-plugins/vesta-accounting-reliability.php" "$base/plugins/bazara/classes/class.bazara.api.php" > "$backup/financial-code.sha256"
docker cp "$stage" vc-vesta:/tmp/vesta-channel-accounts-check
for f in vesta-sms-login.php vesta-channel-customers.php verify-vesta-channel-customers.php;do
 docker exec vc-vesta php -l "/tmp/vesta-channel-accounts-check/$f"
done
docker exec vc-vesta php /tmp/vesta-channel-accounts-check/channel-customers-test.php /tmp/vesta-channel-accounts-check/vesta-sms-login.php /tmp/vesta-channel-accounts-check/vesta-channel-customers.php
changed=no;finished=no
rollback(){
 rc=$?;trap - EXIT
 if [[ "$changed" = yes && "$finished" != yes ]];then
   docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";update_option("vesta_channel_accounts_enabled",false,false);' >/dev/null || true
   cp -p "$backup/vesta-sms-login.php" "$otp"
   rm -f "$mu" /etc/cron.d/vesta-channel-customers
   echo CUSTOMER_CODE_ROLLED_BACK_ACCOUNTS_AND_ORDER_LINKS_PRESERVED=yes
 fi
 exit "$rc"
}
trap rollback EXIT
changed=yes
install -m 0644 "$stage/vesta-sms-login.php" "$otp.channel.tmp"
mv "$otp.channel.tmp" "$otp"
install -m 0644 "$stage/vesta-channel-customers.php" "$mu.tmp"
mv "$mu.tmp" "$mu"
docker exec -i vc-vesta php -d display_errors=0 -d memory_limit=768M < "$stage/verify-vesta-channel-customers.php"
# Enable and backfill only reviewed current-month guest purchases. Save customer references, no financial changes.
docker exec -e VESTA_CHANNEL_ACCOUNTS_APPLY=yes -i vc-vesta php -d display_errors=0 -d memory_limit=768M < "$stage/verify-vesta-channel-customers.php" | tee "$backup/acceptance.log"
grep -q '^CHANNEL_ACCOUNT_ACCEPTANCE=passed' "$backup/acceptance.log"
sha256sum -c "$backup/financial-code.sha256"
install -m 0644 "$stage/vesta-channel-customer-worker.php" /srv/vestacutella/repo/scripts/vesta-channel-customer-worker.php
cat >/etc/cron.d/vesta-channel-customers <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/5 * * * * root flock -n /run/lock/vesta-channel-customer-worker.lock timeout 180 bash -c 'docker exec -u www-data -i vc-vesta php -d display_errors=0 -d memory_limit=512M < /srv/vestacutella/repo/scripts/vesta-channel-customer-worker.php' >>/var/log/vesta-channel-customer-worker.log 2>&1
CRON
chmod 0644 /etc/cron.d/vesta-channel-customers
for path in / /my-account/ /checkout/;do
 page=$(mktemp)
 code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 35 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' -o "$page" -w '%{http_code}' "https://vesta-cosmetics.ir$path")
 echo "CHANNEL_HEALTH=$path HTTP=$code"
 [[ "$code" = 200 || "$path:$code" = /checkout/:302 ]]
 if [[ "$path" = /my-account/ ]];then grep -q vesta-otp-login "$page";fi
 rm -f "$page"
done
cat >/etc/logrotate.d/vesta-channel-customers <<'ROTATE'
/var/log/vesta-channel-customer-worker.log {
 daily
 rotate 14
 compress
 missingok
 notifempty
 copytruncate
}
ROTATE
finished=yes
trap - EXIT
echo CHANNEL_CUSTOMER_ACCOUNTS_LIVE=yes
