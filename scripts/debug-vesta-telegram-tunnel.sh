#!/usr/bin/env bash
set -uo pipefail
PORT=11444
GW="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
echo "docker_gw=$GW"
echo '=== SSH DEBUG TEMPORARY FORWARD ==='
LOG=/tmp/vesta-ssh-forward-debug.log
ssh -vv -N -T -i /root/.ssh/vesta_strato_telegram_2026 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=10 -o GatewayPorts=yes -L "$GW:$PORT:api.telegram.org:443" vesta-telegram-tunnel@217.154.208.41 >"$LOG" 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true;wait "$PID" 2>/dev/null || true;rm -f "$LOG"' EXIT
sleep 3
kill -0 "$PID" 2>/dev/null && echo 'ssh_alive=yes' || echo 'ssh_alive=no'
ss -ltn "( sport = :$PORT )" | tail -n 3
echo '=== Host TCP socket ==='
timeout 4 bash -c 'echo >/dev/tcp/"$1"/"$2"' bash "$GW" "$PORT" >/dev/null 2>&1 && echo "host_bridge_tcp=reachable" || echo "host_bridge_tcp=blocked"
echo '=== Docker TCP socket ==='
docker exec -e VC_GW="$GW" -e VC_PORT="$PORT" vc-vesta bash -lc 'timeout 4 bash -c "echo >/dev/tcp/$VC_GW/$VC_PORT"' >/dev/null 2>&1 && echo "container_bridge_tcp=reachable" || echo "container_bridge_tcp=blocked"
echo '=== Docker cURL TLS forwarded to STRATO ==='
docker exec -e GW="$GW" -e PORT="$PORT" vc-vesta php -d display_errors=0 -r '
$ch=curl_init("https://api.telegram.org/");
curl_setopt($ch,CURLOPT_CONNECT_TO,array("api.telegram.org:443:".getenv("GW").":".getenv("PORT")));
curl_setopt($ch,CURLOPT_RETURNTRANSFER,true);
curl_setopt($ch,CURLOPT_FOLLOWLOCATION,false);
curl_setopt($ch,CURLOPT_CONNECTTIMEOUT,4);
curl_setopt($ch,CURLOPT_TIMEOUT,8);
curl_exec($ch);
echo "http=".curl_getinfo($ch,CURLINFO_HTTP_CODE)." curl_errno=".curl_errno($ch)." phase_tcp=".curl_getinfo($ch,CURLINFO_CONNECT_TIME)." phase_tls=".curl_getinfo($ch,CURLINFO_APPCONNECT_TIME)."\n";
curl_close($ch);
' || true
echo '=== SSH forward channel results, no private information ==='
grep -Ei 'Authenticated to|local forwarding listening|direct-tcpip|open failed|administratively prohibited|connect failed|channel [0-9]+: open|remote forward|connection refused|Permission denied|not permitted|could not resolve|exiting' "$LOG" | tail -n 36 | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP]/g' || true
echo VESTA_TUNNEL_DEBUG_COMPLETE
