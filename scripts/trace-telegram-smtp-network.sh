#!/usr/bin/env bash
set -uo pipefail
echo '=== NETWORK QUICK TEST ==='
if command -v dig >/dev/null; then
 for host in api.telegram.org google.com cloudflare.com server135s.irwebspace.com; do
  echo "name=$host"
  echo -n "ipv4=";dig @1.1.1.1 +short A "$host"|head -n 4|paste -sd',' -
  echo -n "ipv6=";dig @1.1.1.1 +short AAAA "$host"|head -n 3|paste -sd',' -
 done
fi
for url in 'https://api.telegram.org/' 'https://www.google.com/' 'https://www.cloudflare.com/'; do
 echo "url=$url"
 curl -4 -kfsS --max-time 8 -o /dev/null -w 'IPv4_http=%{http_code} tcp=%{time_connect} tls=%{time_appconnect}\n' "$url" 2>&1 | cut -c1-230 || true
done
echo "telegram_IP_direct_149.154.166.110"
curl -4 -ksS --max-time 8 --resolve 'api.telegram.org:443:149.154.166.110' -o /dev/null -w 'direct_http=%{http_code} tcp=%{time_connect} tls=%{time_appconnect}\n' 'https://api.telegram.org/' 2>&1 | cut -c1-230 || true
echo "telegram_IP_direct_149.154.167.220"
curl -4 -ksS --max-time 8 --resolve 'api.telegram.org:443:149.154.167.220' -o /dev/null -w 'direct_http=%{http_code} tcp=%{time_connect} tls=%{time_appconnect}\n' 'https://api.telegram.org/' 2>&1 | cut -c1-230 || true
echo '=== PRESENT HOST PROXY CONFIG (NO VALUES) ==='
env | cut -d= -f1 | grep -Ei '(https?_proxy|all_proxy|no_proxy|socks|v2ray)' || true
for port in 1080 10808 10809 7890 8080; do
 timeout 1 bash -c 'echo >/dev/tcp/127.0.0.1/"$1"' bash "$port" >/dev/null 2>&1 && echo "local_proxy_possible_port=$port" || true
done
echo '=== SMTP DNS SENDER POLICY ==='
for domain in vesta-cosmetics.ir cutellashop.ir; do
 echo "domain=$domain"
 echo -n "SPF=";dig @1.1.1.1 +short TXT "$domain"|tr -d '"'|grep -i 'v=spf1'|head -n 1|cut -c1-280
 echo -n "DMARC=";dig @1.1.1.1 +short TXT "_dmarc.$domain"|tr -d '"'|grep -i 'v=DMARC1'|head -n 1|cut -c1-280
done
echo '=== BRIDGE PHP FILE INTROSPECTION (NO CONFIG VALUE) ==='
for site in vesta cutella; do
 pl="$site-bot-bridge"; file="/srv/vestacutella/runtime/$site/wp-content/plugins/$pl/$pl.php"
 echo "site=$site bridge_file_present=$([[ -f "$file" ]] && echo yes || echo no)"
 if [[ -f "$file" ]]; then
  echo 'functions='
  grep -E '^[[:space:]]*(function |public function |private function |protected function )' "$file" | sed -E 's/\(.*/(/' | cut -c1-130 | head -n 70 || true
  echo 'registered entry action names='
  grep -E 'add_action\(|add_filter\(' "$file" | sed -E "s#(['\"][^'\"]{50})[^'\"]*#\1...(truncated)#g" | cut -c1-180 | head -n 65 || true
 fi
done

echo '=== TRUSTED FOREIGN HOST REACHABILITY FROM SHOP ==='
for endpoint in https://smarbiz.sbs/healthz https://solution.smarbiz.sbs/health https://app.aplus-solution.de/; do
 echo "checking=$endpoint"
 curl -4 -ksS --max-time 7 -o /dev/null -w 'http=%{http_code} tcp=%{time_connect} tls=%{time_appconnect} remote=%{remote_ip}\n' "$endpoint" 2>&1 | cut -c1-220 || true
done
echo '=== DIRECT FOREIGN VPS TCP PORT 443 ==='
for ip in 91.107.157.75 217.154.208.41; do
 timeout 4 bash -c 'echo >/dev/tcp/"$1"/443' bash "$ip" >/dev/null 2>&1 && echo "foreign_$ip=reachable" || echo "foreign_$ip=unreachable"
done
echo '=== MAIL HOST DNS ==='
for domain in mail.vesta-cosmetics.ir mail.cutellashop.ir; do
 echo "$domain";dig @1.1.1.1 +short A "$domain" | head -n 5
done

echo NETWORK_MAIL_BOT_TRACE_COMPLETE
