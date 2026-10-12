#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
RUNTIME=$BASE/runtime/vesta
MU="$RUNTIME/wp-content/mu-plugins/30-vesta-telegram-strato-egress.php"
UNIT=/etc/systemd/system/vesta-telegram-strato-tunnel.service
KEY=/root/.ssh/vesta_strato_telegram_2026
FIREWALL=/usr/local/sbin/vesta-telegram-strato-firewall
BACKUP="/srv/backups/vesta-telegram-tunnel-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 -p "$BACKUP"
[[ -s "$KEY" ]] || { echo "Missing private tunnel key";exit 20; }
command -v systemctl >/dev/null
command -v ssh >/dev/null
GW="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
[[ "$GW" =~ ^172\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected Docker gateway";exit 21; }
echo "bridge_gateway=$GW"
[[ ! -e "$UNIT" ]] || { echo "Tunnel service already exists; refusing unsafe overwrite";exit 22; }
[[ ! -e "$FIREWALL" ]] || { echo "Tunnel firewall helper already exists; refusing unsafe overwrite";exit 23; }
old_mu=0
if [[ -f "$MU" ]];then cp -p "$MU" "$BACKUP/old-mu.php";old_mu=1;fi
cleanup() {
  rc=$?
  if [[ "$rc" != 0 ]];then
    echo "ROLLBACK_VESTA_TELEGRAM_ONLY"
    if [[ "$old_mu" == 1 ]];then cp -p "$BACKUP/old-mu.php" "$MU";else rm -f "$MU";fi
    systemctl stop vesta-telegram-strato-tunnel 2>/dev/null || true
    systemctl disable vesta-telegram-strato-tunnel 2>/dev/null || true
    if [[ -x "$FIREWALL" ]];then "$FIREWALL" remove || true;fi
    rm -f "$FIREWALL" "$UNIT"
    systemctl daemon-reload || true
  fi
  exit "$rc"
}
trap cleanup EXIT
echo '=== Install narrowly scoped firewall helper, only container IP and Docker interface ==='
install -d -m 755 /usr/local/sbin
cat >"$FIREWALL" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ACTION="${1:-}"
GW="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
CIP="$(docker inspect vc-vesta -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
BRIDGE="$(ip -o -4 addr show | awk -v gw="$GW" '{split($4,cidr,"/"); if(cidr[1]==gw){print $2;exit}}')"
[[ "$GW" =~ ^172\.[0-9]+\.[0-9]+\.[0-9]+$ && "$CIP" =~ ^172\.[0-9]+\.[0-9]+\.[0-9]+$ && "$BRIDGE" =~ ^br-[a-zA-Z0-9]+$ ]] || exit 22
RULE=(-i "$BRIDGE" -s "$CIP/32" -d "$GW/32" -p tcp --dport 11443 -j ACCEPT)
case "$ACTION" in
  add)
    iptables -w -C INPUT "${RULE[@]}" 2>/dev/null || iptables -w -I INPUT 1 "${RULE[@]}"
    ;;
  remove)
    iptables -w -C INPUT "${RULE[@]}" 2>/dev/null && iptables -w -D INPUT "${RULE[@]}" || true
    ;;
  *) exit 2 ;;
esac
SH
chmod 700 "$FIREWALL"
cat >"$UNIT" <<UNIT
[Unit]
Description=Vesta order notifications secure tunnel to owned STRATO Telegram egress
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=$FIREWALL add
ExecStart=/usr/bin/ssh -N -T -i $KEY -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o GatewayPorts=yes -L $GW:11443:api.telegram.org:443 vesta-telegram-tunnel@217.154.208.41
ExecStopPost=$FIREWALL remove
Restart=always
RestartSec=5
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 "$UNIT"
systemctl daemon-reload
systemctl enable --now vesta-telegram-strato-tunnel
sleep 6
echo '=== Tunnel health ==='
systemctl is-active --quiet vesta-telegram-strato-tunnel || { journalctl -u vesta-telegram-strato-tunnel --no-pager -n 12 | tail -n 12; exit 30; }
BOUND="$(ss -ltn '( sport = :11443 )' | awk 'NR>1{print $4}' | head -n3)"
echo "bind=$BOUND"
echo "$BOUND" | grep -Fq "$GW:11443" || { echo "Tunnel is not bound to private Docker gateway";exit 31; }
if echo "$BOUND" | grep -Eq '(^| )0\.0\.0\.0:11443|\*:11443|\[::\]:11443';then echo 'Unexpected public tunnel listener';exit 32;fi
echo '=== Direct cURL through private SSH forwarded endpoint ==='
docker exec -e TUNNEL_GATEWAY="$GW" vc-vesta php -d display_errors=0 -r '
 $ch=curl_init("https://api.telegram.org/");
 curl_setopt($ch,CURLOPT_CONNECT_TO,array("api.telegram.org:443:".getenv("TUNNEL_GATEWAY").":11443"));
 curl_setopt($ch,CURLOPT_FOLLOWLOCATION,false);
 curl_setopt($ch,CURLOPT_RETURNTRANSFER,true);
 curl_setopt($ch,CURLOPT_CONNECTTIMEOUT,6);
 curl_setopt($ch,CURLOPT_TIMEOUT,12);
 curl_exec($ch);
 $code=curl_getinfo($ch,CURLINFO_HTTP_CODE);
 $errno=curl_errno($ch);
 echo "tunnel_curl_http=$code errno=$errno\n";
 curl_close($ch);
 if($errno!==0 || $code<200 || $code>399)exit(34);
'
echo '=== Install narrowly scoped WordPress cURL transport interception ==='
mkdir -p "$(dirname "$MU")"
cat >"$MU" <<PHP
<?php
/**
 * Plugin Name: Vesta owned STRATO Telegram egress
 * Description: Sends only api.telegram.org WordPress HTTP/cURL requests over the private SSH tunnel.
 */
if (!defined('ABSPATH')) { exit; }
add_action('http_api_curl', function (\$handle, \$parsed_args, \$url) {
    if (!defined('CURLOPT_CONNECT_TO')) { return; }
    \$host = wp_parse_url(\$url, PHP_URL_HOST);
    if (!is_string(\$host) || strtolower(\$host) !== 'api.telegram.org') { return; }
    curl_setopt(\$handle, CURLOPT_CONNECT_TO, array('api.telegram.org:443:$GW:11443'));
    curl_setopt(\$handle, CURLOPT_IPRESOLVE, CURL_IPRESOLVE_V4);
}, 100, 3);
PHP
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/30-vesta-telegram-strato-egress.php
echo '=== Verify WordPress HTTP API through SSH tunnel ==='
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 $r=wp_remote_get("https://api.telegram.org/",array("timeout"=>12,"redirection"=>0));
 if(is_wp_error($r)){echo "WP_TELEGRAM_ERROR=".preg_replace("/[^a-z0-9_-]/i","",$r->get_error_code())."\n";exit(35);}
 $code=(int)wp_remote_retrieve_response_code($r);
 echo "wp_telegram_http=$code\n";
 if($code<200 || $code>399)exit(36);
'
echo '=== Plugin Telegram transport functions ==='
PL="$RUNTIME/wp-content/plugins/order-notification-for-telegram-bot"
for name in wp_remote_post wp_remote_get curl_init curl_exec file_get_contents;do
  n="$(grep -RhoE --include='*.php' "$name" "$PL/includes/common/helper/TelegramBot.php" 2>/dev/null | wc -l || true)"
  echo "plugin_uses_$name=$n"
done
echo '=== Store pages after egress fix ==='
for p in / /shop/ /my-account/; do
  code="$(curl -ksS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "$p HTTP=$code"
  [[ "$code" == 200 ]] || exit 37
done
trap - EXIT
echo VESTA_TELEGRAM_STRATO_TUNNEL_LIVE_OK
