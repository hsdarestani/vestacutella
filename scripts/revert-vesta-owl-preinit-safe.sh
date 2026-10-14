#!/usr/bin/env bash
set -euo pipefail
P=/srv/vestacutella/runtime/vesta/wp-content/mu-plugins/vc-vesta-owl-init-mobile.php
if [[ -e "$P" ]];then
  grep -q "vc-owl-preinit-layout" "$P" || { echo "Unknown plugin content, refusing removal";exit 31;}
  rm -f "$P"
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' || true
  echo "Removed targeted Owl CSS file after failed browser verification"
else
  echo "Guarded Owl CSS file not present; no rollback needed"
fi
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(curl --noproxy "*" -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://$d/")"
 echo "$d http=$c"
 [[ "$c" == 200 ]] || exit 32
done
echo "SAFE_CLS_ROLLBACK_COMPLETE"
