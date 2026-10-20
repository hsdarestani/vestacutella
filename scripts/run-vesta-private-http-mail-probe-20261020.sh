#!/usr/bin/env bash
# Exactly one admin-only email from real WordPress HTTP PHP runtime.
set -euo pipefail
umask 077
SRC=/tmp/vesta-http-cron-mail-probe-20261020.php
DEST=/srv/vestacutella/runtime/vesta/wp-content/mu-plugins/vc-mail-probe-oct20.php
test -s "$SRC"
test ! -e "$DEST"
cleanup(){
  rm -f "$DEST"
  docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";delete_option("vc_vesta_mail_probe_token_20261020");delete_option("vc_vesta_mail_context_result_20261020");wp_clear_scheduled_hook("vc_vesta_internal_mail_context_probe_20261020");' >/dev/null 2>&1 || true
}
trap cleanup EXIT
install -m 644 "$SRC" "$DEST";chown 33:33 "$DEST"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-mail-probe-oct20.php
TOKEN="$(docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
delete_option("vc_vesta_mail_context_result_20261020");
$nonce=wp_generate_password(48,false,false);
add_option("vc_vesta_mail_probe_token_20261020",$nonce,"",false);
echo $nonce;
')"
[[ "${#TOKEN}" == 48 ]] || exit 12
echo "SIGNED_POST_PROBE_START"
response="$(curl --noproxy '*' -kLsS --max-time 55 --resolve vesta-cosmetics.ir:443:127.0.0.1 -X POST -H "X-VC-Mail-Probe-Token: $TOKEN" --data 'probe=run' 'https://vesta-cosmetics.ir/?vc_mail_context_probe=1' -w ' HTTP:%{http_code}')"
unset TOKEN
case "$response" in *PROBE_EXECUTED*HTTP:200*) echo "HTTP_PROBE_AUTHORIZED_EXECUTED";; *) echo "HTTP_PROBE_NOT_EXECUTED";exit 15;; esac
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";$v=get_option("vc_vesta_mail_context_result_20261020",false);
if(!is_array($v)||($v["state"]??"")!=="finished"){echo "PROBE_RESULT_MISSING\n";exit(21);}
foreach($v as $k=>$value)echo "HTTP_PROBE_".preg_replace("/[^a-z0-9_]/i","",$k)."=".preg_replace("/[^a-z0-9_:-]/i","",(string)$value)."\n";
'
echo "HTTP_POST_MAIL_CONTEXT_PROBE_COMPLETE"
