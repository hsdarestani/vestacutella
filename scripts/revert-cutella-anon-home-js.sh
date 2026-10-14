#!/usr/bin/env bash
set -euo pipefail
PLUGIN=/srv/vestacutella/runtime/cutella/wp-content/mu-plugins/vc-cutella-anon-home-no-revslider.php
if [[ -f "$PLUGIN" ]];then
 grep -q 'vc_cutella_guest_js_optout' "$PLUGIN" || { echo "ABORT unknown plugin";exit 21; }
 rm -f "$PLUGIN"
 docker exec vc-cutella php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' || true
 echo "Restored Cutella homepage JS"
fi
for domain in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 status="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$domain:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$domain/")"
 echo "$domain status=$status"
 [[ "$status" == 200 ]] || exit 22
done
echo "CUTELLA_HOMEPAGE_JS_ROLLBACK_OK"
