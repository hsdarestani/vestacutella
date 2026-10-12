#!/usr/bin/env bash
set -euo pipefail
GW="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
CIP="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
BRIDGE="$(ip -o -4 addr show | awk -v gw="$GW" '{split($4,cidr,"/"); if(cidr[1]==gw){print $2;exit}}')"
PORT=11445
[[ "$GW" =~ ^172\.[0-9]+\.[0-9]+\.[0-9]+$ && "$CIP" =~ ^172\.[0-9]+\.[0-9]+\.[0-9]+$ && "$BRIDGE" =~ ^br-[a-zA-Z0-9]+$ ]] || { echo "Unexpected docker network";exit 10; }
echo "gateway=$GW bridge=$BRIDGE container=$CIP"
echo '=== Host firewall policy ==='
command -v iptables
iptables -S INPUT | head -n 35 | sed -E 's/--comment ".*"/--comment [redacted]/' || true
echo '=== Start temporary Telegram tunnel ==='
LOG=/tmp/vesta-debug-tunnel-firewall.log
ssh -N -T -i /root/.ssh/vesta_strato_telegram_2026 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -L "$GW:$PORT:api.telegram.org:443" vesta-telegram-tunnel@217.154.208.41 >"$LOG" 2>&1 &
PID=$!
RULE=(-i "$BRIDGE" -s "$CIP/32" -d "$GW/32" -p tcp --dport "$PORT" -j ACCEPT)
inserted=0
finish(){
 if [[ "$inserted" == 1 ]];then iptables -w -D INPUT "${RULE[@]}" 2>/dev/null || true;fi
 kill "$PID" 2>/dev/null || true
 wait "$PID" 2>/dev/null || true
 rm -f "$LOG"
}
trap finish EXIT
sleep 2
echo '=== Before isolated firewall rule ==='
docker exec -e TEST_GW="$GW" -e TEST_PORT="$PORT" vc-vesta php -r '$s=@fsockopen(getenv("TEST_GW"), (int)getenv("TEST_PORT"),$e,$m,2);echo "before_container_tcp=".($s?"reachable":"blocked")."\n";if($s)fclose($s);'
echo '=== Allow only Vesta container IP to temporary private test tunnel ==='
iptables -w -I INPUT 1 "${RULE[@]}"
inserted=1
echo '=== After isolated firewall rule ==='
docker exec -e TEST_GW="$GW" -e TEST_PORT="$PORT" vc-vesta php -r '$s=@fsockopen(getenv("TEST_GW"),(int)getenv("TEST_PORT"),$e,$m,3);echo "after_container_tcp=".($s?"reachable":"blocked")."\n";if($s)fclose($s);else exit(4);'
echo '=== TLS GET through restricted tunnel ==='
docker exec -e TEST_GW="$GW" -e TEST_PORT="$PORT" vc-vesta php -r '
$h=curl_init("https://api.telegram.org/");
curl_setopt($h,CURLOPT_CONNECT_TO,array("api.telegram.org:443:".getenv("TEST_GW").":".getenv("TEST_PORT")));
curl_setopt($h,CURLOPT_RETURNTRANSFER,true);
curl_setopt($h,CURLOPT_FOLLOWLOCATION,false);
curl_setopt($h,CURLOPT_CONNECTTIMEOUT,5);
curl_setopt($h,CURLOPT_TIMEOUT,10);
curl_exec($h);$code=curl_getinfo($h,CURLINFO_RESPONSE_CODE);$err=curl_errno($h);
echo "telegram_tunnel_http=$code curl_errno=$err\n";curl_close($h);if($err || $code < 200 || $code >= 400)exit(5);
'
echo '=== SSH tunnel errors ==='
grep -E 'open failed|administratively prohibited|Permission denied|Connection refused' "$LOG" | tail -n 5 || true
echo '=== Temporary firewall rule removal ==='
iptables -w -D INPUT "${RULE[@]}"
inserted=0
echo VESTA_FIREWALL_TUNNEL_TEST_PASSED
