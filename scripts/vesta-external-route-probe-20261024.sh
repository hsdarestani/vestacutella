#!/usr/bin/env bash
set -uo pipefail
echo "PUBLIC-EDGE-PROBE $(date -u +%Y-%m-%dT%H:%M:%SZ)"
for host in vesta-cosmetics.ir www.vesta-cosmetics.ir cutellashop.ir; do
 echo "HOST=$host"; getent ahostsv4 "$host" | awk '{print $1}' | sort -u | head -6
 for path in "/" "/wp-login.php"; do
  curl -4 -sS --connect-timeout 7 --max-time 16 -o /dev/null -w "EDGE $host $path status=%{http_code} remote=%{remote_ip} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} err=%{errormsg}\n" "https://$host$path" || true
 done
done
echo "DIRECT-ORIGIN-TEST"
for addr in 193.177.242.64; do
 for path in / /wp-login.php; do
 curl -k -4 -sS --connect-timeout 7 --max-time 16 --resolve "vesta-cosmetics.ir:443:$addr" -o /dev/null -w "ORIGIN $addr $path status=%{http_code} remote=%{remote_ip} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total} err=%{errormsg}\n" "https://vesta-cosmetics.ir$path" || true
 done
done
echo PROBE_DONE
