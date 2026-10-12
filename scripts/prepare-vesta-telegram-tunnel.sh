#!/usr/bin/env bash
set -euo pipefail
echo '=== Check STRATO SSH route ==='
timeout 6 bash -c 'echo >/dev/tcp/217.154.208.41/22' >/dev/null 2>&1 && echo 'strato_ssh_22=reachable' || echo 'strato_ssh_22=blocked'
echo '=== Docker bridge gateway and curl capabilities ==='
docker inspect vc-vesta -f 'network={{range $k,$v := .NetworkSettings.Networks}}{{$k}} gw={{$v.Gateway}}{{end}}'
docker exec vc-vesta php -r 'echo "curl_extension=".(extension_loaded("curl")?"yes":"no").PHP_EOL; echo "CURLOPT_CONNECT_TO=".(defined("CURLOPT_CONNECT_TO")?"yes":"no").PHP_EOL;'
echo '=== Order notifications Telegram transport (function names only) ==='
PL=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot
grep -RiloE --include='*.php' 'wp_remote_post|wp_remote_get|curl_init|file_get_contents' "$PL" | sed "s#^$PL/##" | head -n 20 || true
echo '=== Set up private local SSH key for this outbound forwarding ONLY ==='
install -d -m 700 /root/.ssh
KEY=/root/.ssh/vesta_strato_telegram_2026
if [[ ! -s "$KEY" ]]; then
  umask 077
  ssh-keygen -q -t ed25519 -N '' -C 'vesta-telegram-tunnel-2026' -f "$KEY"
fi
chmod 600 "$KEY"
ssh-keygen -lf "$KEY.pub"
echo 'STRATO_TUNNEL_PUBLIC_KEY_START'
cat "$KEY.pub"
echo 'STRATO_TUNNEL_PUBLIC_KEY_END'
echo VESTA_TUNNEL_PREFLIGHT_OK
