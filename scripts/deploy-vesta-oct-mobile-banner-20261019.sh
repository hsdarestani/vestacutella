#!/usr/bin/env bash
# Add mobile-specific WebP sources for two October Vesta hero banners.
set -euo pipefail
ROOT=/srv/vestacutella/runtime/vesta
UP="$ROOT/wp-content/uploads/2026/10"
PLUGIN="$ROOT/wp-content/mu-plugins/vc-vesta-oct-banner-webp.php"
SOURCE=/tmp/vc-vesta-oct-banner-webp.php
FILES="IMG_9282-1.png IMG_9279-1.png"
BACKUP="/srv/backups/vesta-mobile-banners-$(date -u +%Y%m%dT%H%M%SZ)"
status(){ curl --noproxy '*' -kLsS --max-time 25 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
test -s "$SOURCE"
test -s "$ROOT/wp-content/mu-plugins/vc-vesta-hero-webp.php"
[[ ! -e "$PLUGIN" ]] || { echo "ABORT existing banner helper";exit 11; }
[[ "$(docker exec vc-vesta php -r 'echo function_exists("imagewebp")?"yes":"no";')" == yes ]] || exit 12
for f in $FILES;do test -s "$UP/$f";test ! -e "$UP/$f.vc20261019-mobile.webp";done
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$d" /)"
 echo "PRECHECK $d $code"
 [[ "$code" == 200 ]] || exit 13
done
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
sha256sum "$UP/IMG_9282-1.png" "$UP/IMG_9279-1.png" > "$BACKUP/originals.sha256"
changed=0;finished=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$changed" == 1 && "$finished" != 1 ]];then
  echo "MOBILE_BANNER_ROLLBACK rc=$rc"
  rm -f "$PLUGIN"
  for f in $FILES;do rm -f "$UP/$f.vc20261019-mobile.webp";done
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$rc"
}
trap rollback EXIT
changed=1
for f in $FILES;do
 docker exec -e ORIGINAL="/var/www/html/wp-content/uploads/2026/10/$f" vc-vesta php -d memory_limit=256M -r '
 $in=getenv("ORIGINAL");$out=$in.".vc20261019-mobile.webp";
 $im=@imagecreatefrompng($in);if(!$im)exit(21);
 $w=imagesx($im);$h=imagesy($im);
 if($w<400||$h<200)exit(22);
 $nw=min(850,$w);$nh=(int)round($h*$nw/$w);
 $dst=imagecreatetruecolor($nw,$nh);imagealphablending($dst,false);imagesavealpha($dst,true);
 $alpha=imagecolorallocatealpha($dst,0,0,0,127);imagefilledrectangle($dst,0,0,$nw,$nh,$alpha);
 if(!imagecopyresampled($dst,$im,0,0,0,0,$nw,$nh,$w,$h))exit(23);
 $temp=$out.".tmp";if(!imagewebp($dst,$temp,82))exit(24);
 imagedestroy($im);imagedestroy($dst);
 $check=@imagecreatefromwebp($temp);
 if(!$check||imagesx($check)!==$nw||imagesy($check)!==$nh)exit(25);
 imagedestroy($check);
 if(filesize($temp)<3000||filesize($temp)>=filesize($in))exit(26);
 if(!rename($temp,$out))exit(27);
 echo "WEBP_CREATED ".basename($in)." orig_bytes=".filesize($in)." webp_bytes=".filesize($out)." width=".$nw."\n";
 '
 chown 33:33 "$UP/$f.vc20261019-mobile.webp"
 chmod 644 "$UP/$f.vc20261019-mobile.webp"
done
install -m 644 "$SOURCE" "$PLUGIN";chown 33:33 "$PLUGIN"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-oct-banner-webp.php
for f in $FILES;do
 resp="$(curl --noproxy '*' -kLsS --max-time 22 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code} %{content_type}' "https://vesta-cosmetics.ir/wp-content/uploads/2026/10/$f.vc20261019-mobile.webp")"
 echo "ASSET $f $resp"
 [[ "$resp" == "200 image/webp" ]] || exit 31
done
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "HOME_CACHE_REFRESHED\n";}'
# Nginx can return a stale entry during its background cache update.
# Poll verified public HTML rather than assuming a single request is fresh.
sleep 14
tmp="$(mktemp)"
fresh=0
for attempt in 1 2 3 4 5 6 7 8;do
 curl --noproxy '*' -kLsS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o "$tmp" https://vesta-cosmetics.ir/
 preload=no;picture=no
 grep -q 'id="vc-oct-banner-preload"' "$tmp" && preload=yes
 grep -q 'class="vc-oct-banner-mobile-webp"' "$tmp" && picture=yes
 echo "HTML_FRESHNESS attempt=$attempt preload=$preload picture=$picture"
 if [[ "$preload" == yes && "$picture" == yes ]];then fresh=1;break;fi
 sleep 4
done
[[ "$fresh" == 1 ]] || { echo "FAIL optimized HTML never appeared";rm -f "$tmp";exit 32; }
for f in $FILES;do grep -q "$f.vc20261019-mobile.webp" "$tmp" || { echo "FAIL missing WebP $f";rm -f "$tmp";exit 34; };done
rm -f "$tmp"
sha256sum -c "$BACKUP/originals.sha256" || exit 35
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$d" /)";echo "POSTCHECK $d $code"
 [[ "$code" == 200 ]] || exit 36
done
for p in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 code="$(status vesta-cosmetics.ir "$p")";echo "VESTA_CHECK $p $code"
 [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 37
done
finished=1;trap - EXIT
echo "VESTA_OCT_MOBILE_BANNERS_DEPLOYED originals_unchanged=yes backup=$BACKUP"
