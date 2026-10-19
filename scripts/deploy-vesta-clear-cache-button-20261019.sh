#!/usr/bin/env bash
# Vesta-only WP Rocket page cache purge and protected toolbar action.
set -euo pipefail
umask 077
SRC=/tmp/vc-vesta-clear-cache.php
DEST=/srv/vestacutella/runtime/vesta/wp-content/mu-plugins/vc-vesta-clear-cache.php
BACKUP=/srv/backups/vesta-clear-cache-button-$(date -u +%Y%m%dT%H%M%SZ)
status(){ curl --noproxy '*' -kLsS --max-time 30 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
test -s "$SRC"
if test -f "$DEST" && ! cmp -s "$SRC" "$DEST";then echo "EXISTING_CACHE_TOOL_DIFFERENT_ABORT";exit 9;fi
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 r="$(status "$site" /)";echo "PRECHECK $site HTTP=$r";[[ "$r" == 200 ]] || exit 10
done
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";if(!function_exists("rocket_clean_domain")){echo "WP_ROCKET_PURGE_UNAVAILABLE\n";exit(11);}
 echo "WP_ROCKET_PURGE_READY\n";
'
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
created=0
complete=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$created" == 1 && "$complete" != 1 ]]; then
  rm -f "$DEST"
  echo "ROLLBACK_CACHE_BUTTON rc=$rc"
 fi
 exit "$rc"
}
trap rollback EXIT
if [[ ! -e "$DEST" ]];then
 install -m 644 "$SRC" "$DEST"
 chown 33:33 "$DEST"
 created=1
fi
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-clear-cache.php
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 foreach(["vc_vesta_cache_toolbar","vc_vesta_cache_purge_action","vc_vesta_cache_tools_menu"] as $f) if(!function_exists($f))exit(12);
 foreach(["admin_bar_menu","admin_menu","admin_post_vc_vesta_purge_page_cache"] as $h)if(!has_action($h)){echo "MISSING_HOOK_".$h."\n";exit(13);}
 echo "VESTA_CACHE_CONTROL_HOOKS_OK\n";
'
echo "=== CLEARING VESTA WP ROCKET PAGE CACHE NOW ==="
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 rocket_clean_domain();
 echo "VESTA_WP_ROCKET_CACHE_CLEARED_UTC=".gmdate("c")."\n";
'
# Nginx's 12-second anonymous microcache is shared with Cutella but keyed by hostname.
# It naturally expires and must NOT be globally cleared to avoid disrupting Cutella.
sleep 15
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 r="$(status "$site" /)";echo "POSTCHECK $site HTTP=$r";[[ "$r" == 200 ]] || exit 14
done
for page in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 r="$(status vesta-cosmetics.ir "$page")";echo "CHECK $page HTTP=$r"
 [[ "$r" == 200 || "$r" == 301 || "$r" == 302 ]] || exit 15
done
docker exec vc-nginx nginx -t
complete=1;trap - EXIT
echo "VESTA_CACHE_CONTROL_INSTALLED_AND_CACHE_CLEARED"
