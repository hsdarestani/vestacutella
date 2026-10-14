#!/usr/bin/env bash
# Remove only the new scoped CSS extension if independent verification fails.
set -euo pipefail
P=/srv/vestacutella/runtime/vesta/wp-content/mu-plugins/vc-vesta-optimized-product-render.php
if [[ -e "$P" ]];then
 grep -q 'vc-mobile-product-render' "$P" || { echo "ABORT unknown plugin; manual review needed";exit 21; }
 rm -f "$P"
 docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' || true
 echo "Reverted Vesta product rendering CSS."
fi
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")"
 echo "$host status=$code"
 [[ "$code" == 200 ]] || exit 22
done
echo "VESTA_RENDER_VISIBILITY_REVERT_SUCCESS"
