#!/usr/bin/env bash
# Vesta hero image optimization: never replace original PNG images.
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
CONTENT="$BASE/wp-content"
MU="$CONTENT/mu-plugins"
PLUGIN="$MU/vc-vesta-secondary-webp.php"
STAMP=vc20261014b
BACKUP="/srv/backups/vesta-secondary-webp-$(date -u +%Y%m%dT%H%M%SZ)"
FILES="
$CONTENT/uploads/2026/04/2-1.png
$CONTENT/uploads/2026/04/4-1.png
$CONTENT/uploads/2026/04/3-1.png
$CONTENT/uploads/2026/04/1-1.png
$CONTENT/uploads/2026/06/IMG_4060.jpeg
"
status() {
 curl --noproxy '*' -kLsS --max-time 22 --resolve vesta-cosmetics.ir:443:127.0.0.1 \
 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$1"
}
echo "=== WebP secondary images preflight ==="
[[ "$(status /)" == 200 ]] || exit 11
[[ "$(docker exec vc-vesta php -r 'echo function_exists("imagewebp")?"yes":"no";')" == yes ]] || exit 12
[[ ! -e "$PLUGIN" ]] || { echo "ABORT: image plugin exists";exit 13;}
for file in $FILES;do
 test -s "$file" || exit 14
 [[ ! -e "$file.$STAMP.webp" ]] || exit 15
done
mkdir -p "$BACKUP" "$MU"
chmod 700 "$BACKUP"
echo "Original image files will never be modified."
if [[ -d "$CONTENT/cache/wp-rocket/vesta-cosmetics.ir" ]];then
 mkdir -p "$BACKUP/home-cache"
 find "$CONTENT/cache/wp-rocket/vesta-cosmetics.ir" -maxdepth 1 -type f -name 'index*' -exec cp -p '{}' "$BACKUP/home-cache/" \;
fi
modified=0
rollback() {
 code=$?
 trap - EXIT
 if [[ "$modified" == 1 ]];then
  echo "Rollback because image or homepage verification failed, rc=$code"
  rm -f "$PLUGIN"
  for f in $FILES;do rm -f "$f.$STAMP.webp";done
  if [[ -d "$BACKUP/home-cache" ]];then
   cp -p "$BACKUP/home-cache/"* "$CONTENT/cache/wp-rocket/vesta-cosmetics.ir/" 2>/dev/null || true
  fi
  docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home"))rocket_clean_home();' >/dev/null 2>&1 || true
 fi
 exit "$code"
}
trap rollback EXIT
modified=1
for file in $FILES;do
 inside="$(printf '%s' "$file" | sed "s#^$BASE#/var/www/html#")"
 docker exec -e VC_IN="$inside" -e VC_OUT="$inside.$STAMP.webp" vc-vesta php -r '
 $a=getenv("VC_IN");$b=getenv("VC_OUT");$im=@(preg_match("/\.jpe?g$/i",$a)?imagecreatefromjpeg($a):imagecreatefrompng($a));
 if(!$im){fwrite(STDERR,"Cannot decode PNG\n");exit(21);}
 $tmp=$b.".tmp";
 if(!imagewebp($im,$tmp,86)){exit(22);}
 $check=@imagecreatefromwebp($tmp);
 $same=$check&&imagesx($check)===imagesx($im)&&imagesy($check)===imagesy($im);
 if($check)imagedestroy($check);imagedestroy($im);
 if(!$same||filesize($tmp)<10000||filesize($tmp)>=filesize($a)){@unlink($tmp);exit(23);}
 if(!rename($tmp,$b))exit(24);
 echo basename($a)." before_kb=".round(filesize($a)/1024)." after_kb=".round(filesize($b)/1024)."\n";
 '
 chown 33:33 "$file.$STAMP.webp"
 chmod 644 "$file.$STAMP.webp"
done
cat > "$PLUGIN" <<'PHP'
<?php
/* Plugin Name: VC Vesta safe secondary-image WebP picture sources */
if (!defined('ABSPATH')) exit;
if (!function_exists('vc_secondary_picture_buffer')) {
 function vc_secondary_picture_buffer($html) {
  if(!is_string($html)||stripos($html,'<img')===false)return $html;
  $targets=array(
   '/wp-content/uploads/2026/04/2-1.png',
   '/wp-content/uploads/2026/04/4-1.png',
   '/wp-content/uploads/2026/04/3-1.png',
   '/wp-content/uploads/2026/04/1-1.png',
   '/wp-content/uploads/2026/06/IMG_4060.jpeg'
  );
  try {
   $out=preg_replace_callback('~<img\b[^>]*>~i',function($m)use($targets){
    $tag=$m[0];
    if(preg_match('~(?:data-)?srcset\s*=~i',$tag))return $tag;
    if(!preg_match('~\bsrc\s*=\s*(["\x27])([^"\x27]+)\1~i',$tag,$a))return $tag;
    $url=html_entity_decode($a[2],ENT_QUOTES,'UTF-8');
    $path=wp_parse_url($url,PHP_URL_PATH);
    if(!is_string($path)||!in_array($path,$targets,true))return $tag;
    $webp=esc_url($url.'.vc20261014b.webp');
    return '<picture><source type="image/webp" srcset="'.$webp.'">'.$tag.'</picture>';
   },$html,30);
   return is_string($out)?$out:$html;
  }catch(Throwable $e){
   error_log('VC safe picture: rendering fallback');
   return $html;
  }
 }
}
add_filter('rocket_buffer',function($html){
 return is_front_page()&&!is_admin()?vc_secondary_picture_buffer($html):$html;
},1000);
PHP
chown 33:33 "$PLUGIN"
chmod 644 "$PLUGIN"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-secondary-webp.php
echo "=== Validate new images ==="
for file in $FILES;do
 path="$(printf '%s' "$file" | sed "s#^$BASE##")"
 url="https://vesta-cosmetics.ir$path.$STAMP.webp"
 resp="$(curl --noproxy '*' -kLsS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code} %{content_type}' "$url")"
 echo "$path WebP $resp"
 [[ "$resp" == "200 image/webp" ]] || exit 31
done
echo "=== Purge only homepage with WP Rocket ==="
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php";if(function_exists("rocket_clean_home")){rocket_clean_home();echo "cleaned home\n";}'
sleep 2
html="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o "$html" https://vesta-cosmetics.ir/
count="$(grep -o 'type="image/webp"' "$html" | wc -l)"
echo "WebP picture sources on homepage total: $count"
[[ "$count" -ge 9 ]] || { echo "No page changes in WP Rocket cache"; exit 32; }
for file in $FILES;do
 name="$(basename "$file")"
 grep -q "$name.$STAMP.webp" "$html" || exit 33
done
rm -f "$html"
[[ "$(status /)" == 200 ]] || exit 34
for domain in cutellashop.ir app.vesta-cosmetics.ir;do
 result="$(curl --noproxy '*' -kLsS --resolve "$domain:443:127.0.0.1" --max-time 20 -o /dev/null -w '%{http_code}' "https://$domain/")"
 echo "$domain HTTP $result"
 [[ "$result" == 200 ]] || exit 35
done
modified=0
trap - EXIT
echo "VESTA_SECONDARY_WEBP_DEPLOY_OK"
