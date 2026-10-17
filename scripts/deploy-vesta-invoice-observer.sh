#!/usr/bin/env bash
# Deploy passive, self-expiring diagnostics. No plugin activation, network calls or cron dispatch.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
SOURCE=/tmp/vc-vesta-license-observer.php
TARGET="$BASE/wp-content/mu-plugins/vc-vesta-license-observer.php"
BACKUP="/srv/backups/vc-invoice-observer-$(date -u +%Y%m%dT%H%M%SZ)"
test -f "$SOURCE"
test -f "$BASE/wp-config.php"
test -d "$BASE/wp-content/mu-plugins"
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; echo "WP_OK".PHP_EOL;'
for p in / /shop/ /my-account/; do
    code=$(curl -ksS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p")
    echo "baseline $p HTTP=$code"
    test "$code" = 200
done
mkdir -m 700 -p "$BACKUP"
old_file=no
if test -f "$TARGET"; then
    cp -p "$TARGET" "$BACKUP/observer.php"
    old_file=yes
fi
changed=no
done_ok=no
finish() {
    rc=$?
    trap - EXIT
    if [[ "$changed" == yes && "$done_ok" != yes ]]; then
        if [[ "$old_file" == yes ]]; then
            cp -p "$BACKUP/observer.php" "$TARGET"
        else
            rm -f "$TARGET"
        fi
        echo "ROLLED_BACK_OBSERVER rc=$rc"
    fi
    exit "$rc"
}
trap finish EXIT
install -m 0644 "$SOURCE" "$TARGET"
changed=yes
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-license-observer.php
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (!function_exists("vc_invoice_observer_log")) exit(21);
if (has_action("wip-guard-reg_daily_validator") === false) exit(22);
echo "PASSIVE_VALIDATOR_OBSERVER_REGISTERED".PHP_EOL;
'
for p in / /shop/ /my-account/; do
    code=$(curl -ksS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p")
    echo "after_install $p HTTP=$code"
    test "$code" = 200
done
done_ok=yes
trap - EXIT
echo "VESTA_INVOICE_OBSERVER_READY backup=$BACKUP"
