#!/usr/bin/env bash
# Remove frontend Dashicons only from anonymous Cutella homepage.
# WooCommerce checkout, account pages, admins and logged-in customers unchanged.
set -euo pipefail
BASE=/srv/vestacutella/runtime/cutella
P="$BASE/wp-content/mu-plugins/vc-cutella-guest-dashicons.php"
BACKUP="/srv/backups/cutella-dashicons-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP" "$(dirname "$P")"
chmod 700 "$BACKUP"
code(){
 curl --noproxy '*' -kLsS --max-time 25 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"
}
echo "=== Dashicons homepage-only preflight ==="
for d in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 [[ "$(code "$d" /)" == 200 ]] || { echo "ABORT unhealthy $d";exit 21; }
done
[[ ! -e "$P" ]] || { echo "ABORT existing custom hook";exit 22; }
before="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 30 --resolve cutellashop.ir:443:127.0.0.1 "https://cutellashop.ir/" -o "$before"
grep -q 'dashicons' "$before" || { echo "ABORT Dashicons absent in origin HTML already";exit 23; }
rm -f "$before"
if [[ -d "$BASE/wp-content/cache/wp-rocket/cutellashop.ir" ]];then
 mkdir -p "$BACKUP/home-cache"
 find "$BASE/wp-content/cache/wp-rocket/cutellashop.ir" -maxdepth 1 -type f -name 'index*' -exec cp -p '{}' "$BACKUP/home-cache/" \;
fi
modified=0
rollback() {
 rc=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  rm -f "$P"
  docker exec vc-cutella php -r 'require "/var/www/html/wp-load.php"; if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
  echo "Rolled back frontend Dashicons change"
 fi
 exit "$rc"
}
trap rollback EXIT
modified=1
cat > "$P" <<'PHP'
<?php
/* Plugin Name: Cutella anonymous home Dashicons opt-out */
if(!defined('ABSPATH'))exit;
add_action('wp_enqueue_scripts',function(){
 if(is_admin()||!is_front_page()||is_user_logged_in())return;
 // The public home page has no Dashicons DOM uses. Preserve icon CSS everywhere
 // else, including the cart, checkout, account, editor and staff interfaces.
 wp_dequeue_style('dashicons');
},9999);
PHP
chmod 644 "$P"
chown 33:33 "$P"
docker exec vc-cutella php -l /var/www/html/wp-content/mu-plugins/vc-cutella-guest-dashicons.php
docker exec vc-cutella php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();'
sleep 2
html="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 30 --resolve cutellashop.ir:443:127.0.0.1 "https://cutellashop.ir/" -o "$html"
if grep -Eq '(<link[^>]*dashicons|min/1/wp-includes/css/dashicons)' "$html";then
 echo "Dashicons still referenced; abort and roll back";exit 24
fi
grep -q 'cutella-banner' "$html" || { echo "Banner HTML vanished";exit 25; }
grep -q 'cutella-home' "$html" || { echo "Custom homepage markup vanished";exit 26; }
rm -f "$html"
for d in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir;do
 echo "$d home=$(code "$d" /)"
 [[ "$(code "$d" /)" == 200 ]] || exit 27
done
for path in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 result="$(code cutellashop.ir "$path")"
 echo "cutella$path http=$result"
 case "$result" in 200|301|302) ;; *) exit 28;; esac
done
modified=0
trap - EXIT
echo "CUTELLA_GUEST_DASHICONS_OPTIMIZED"
