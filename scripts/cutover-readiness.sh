#!/usr/bin/env bash
set -u
BASE=/srv/vestacutella
SERVER_IP="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"

echo "=== local application checks ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  for p in / /wp-login.php /wp-admin/; do
    code=$(curl --max-time 20 -ksS --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d$p" || true)
    echo "$d $p HTTP=$code"
  done
done

echo "=== DNS cutover state ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  dns_ip="$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -n "$SERVER_IP" && "$dns_ip" == "$SERVER_IP" ]]; then
    echo "$d DNS_POINTS_TO_THIS_SERVER=yes"
  else
    echo "$d DNS_POINTS_TO_THIS_SERVER=no"
  fi
done

echo "=== TLS certificate validity ==="
for pair in "cutella:cutellashop.ir" "vesta:vesta-cosmetics.ir"; do
  name="${pair%%:*}"; domain="${pair#*:}"
  cert="$BASE/runtime/certs/$name/fullchain.pem"
  if [[ -f "$cert" ]]; then
    end="$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)"
    echo "$domain cert_end=$end"
    if openssl x509 -in "$cert" -checkend 604800 -noout >/dev/null 2>&1; then
      echo "$domain cert_valid_more_than_7_days=yes"
    else
      echo "$domain cert_valid_more_than_7_days=no"
    fi
  else
    echo "$domain cert_missing=yes"
  fi
done

echo "=== staging safety ==="
for s in cutella vesta; do
  root="$BASE/runtime/$s"
  if [[ -f "$root/wp-content/mu-plugins/00-vestacutella-migration-safety.php" ]]; then
    echo "$s mail_blocker=enabled"
  else
    echo "$s mail_blocker=disabled"
  fi
  if grep -q "WP_ENVIRONMENT_TYPE.*staging" "$root/wp-config.php" 2>/dev/null; then echo "$s environment=staging"; else echo "$s environment=not_staging"; fi
  if grep -q "DISABLE_WP_CRON.*true" "$root/wp-config.php" 2>/dev/null; then echo "$s wp_cron=disabled"; else echo "$s wp_cron=not_forced_disabled"; fi
  find "$root/wp-content/plugins" -maxdepth 1 -type d -name '*.disabled-for-migration' -printf "$s disabled_plugin=%f\n" 2>/dev/null | sort || true
done

echo "=== containers ==="
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'vc-|NAMES' || true
echo "=== capacity ==="
df -h /
free -h
