#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime

echo "=== verify host cron service ==="
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active cron >/dev/null 2>&1 || systemctl start cron
fi

echo "=== disable request-driven WP Cron ==="
for site in vesta cutella; do
  f="$RUNTIME/$site/wp-config.php"
  WP_FILE="$f" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()
pat=r"define\(\s*['\"]DISABLE_WP_CRON['\"]\s*,\s*(?:true|false)\s*\)\s*;"
repl="define('DISABLE_WP_CRON', true);"
if re.search(pat,s,flags=re.I):
    s=re.sub(pat,repl,s,flags=re.I)
else:
    marker="/* That's all, stop editing!"
    i=s.find(marker)
    s=s[:i]+repl+"\n"+s[i:] if i>=0 else s+"\n"+repl+"\n"
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
  chown 33:33 "$f"
done

echo "=== install reliable host cron ==="
cat >/etc/cron.d/vestacutella-wp-cron <<'CRON'
* * * * * root flock -n /run/lock/vesta-wp-cron.lock docker exec vc-vesta php /var/www/html/wp-cron.php >/dev/null 2>&1
* * * * * root flock -n /run/lock/cutella-wp-cron.lock docker exec vc-cutella php /var/www/html/wp-cron.php >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/vestacutella-wp-cron

if command -v systemctl >/dev/null 2>&1; then
  systemctl reload cron 2>/dev/null || systemctl restart cron
fi

echo "=== run once now ==="
flock -n /run/lock/vesta-wp-cron.lock docker exec vc-vesta php /var/www/html/wp-cron.php >/dev/null 2>&1 || true
flock -n /run/lock/cutella-wp-cron.lock docker exec vc-cutella php /var/www/html/wp-cron.php >/dev/null 2>&1 || true

echo "=== verify ==="
cat /etc/cron.d/vestacutella-wp-cron
for site in vesta cutella; do
  docker exec "vc-$site" php -r 'require "/var/www/html/wp-config.php"; echo "DISABLE_WP_CRON=".(defined("DISABLE_WP_CRON") && DISABLE_WP_CRON ? "true":"false").PHP_EOL;'
done
echo "WP_CRON_TUNING_OK"
