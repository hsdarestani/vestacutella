#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
SOURCE=/tmp/vc-vesta-digipay-mobile.php
TARGET="$BASE/wp-content/mu-plugins/vc-vesta-digipay-mobile.php"
test -s "$SOURCE"
test -d "$(dirname "$TARGET")"
test -s "$BASE/wp-config.php"
umask 077
BACKUP=/srv/backups/vesta-digipay-mobile-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -m 0700 "$BACKUP"
old=no
if [[ -f "$TARGET" ]]; then cp -p "$TARGET" "$BACKUP/previous.php"; old=yes; fi
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --max-time 45 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  [[ "$code" == 200 ]] || { echo "PREFLIGHT_FAILED $path $code";exit 3; }
done
applied=no
undo(){
  code=$?
  trap - EXIT
  if [[ "$applied" == yes ]]; then
    if [[ "$old" == yes ]]; then cp -p "$BACKUP/previous.php" "$TARGET"; else rm -f "$TARGET"; fi
    echo "DIGIPAY_COMPAT_ROLLBACK"
  fi
  exit "$code"
}
trap undo EXIT
install -m 0644 "$SOURCE" "$TARGET"
chown 33:33 "$TARGET"
applied=yes
# Use -r include because the legacy Vesta ionCube environment is sensitive to CLI file parsing.
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if(!function_exists("vc_vesta_normalize_iran_mobile")) exit(10);
$cases=array(
  "09123456789"=>"09123456789",
  "989123456789"=>"09123456789",
  "00989123456789"=>"09123456789",
  "+98 912 345 6789"=>"09123456789",
  "0989123456789"=>"09123456789",
  "۹۱۲۳۴۵۶۷۸۹"=>"09123456789",
  "۰۹۱۲۳۴۵۶۷۸۹"=>"09123456789",
  "٠٩١٢٣٤٥٦٧٨٩"=>"09123456789",
  "02112345678"=>"",
  "0912345678"=>"",
  "091234567899"=>""
);
foreach($cases as $input=>$expected) {
  $actual=vc_vesta_normalize_iran_mobile($input);
  if($actual!==$expected){fwrite(STDERR,"PHONE_CASE_FAILED\n");exit(11);}
}
$o=wc_get_order(101583);
if (!$o || $o->get_payment_method()!=="WCDigiPay") { echo "SAMPLE_ORDER_NOT_FOUND\n"; }
else {
 $raw=$o->get_billing_phone("edit");
 $norm=$o->get_billing_phone("view");
 echo "SAMPLE_ORDER id=101583 raw_digits=".strlen(preg_replace("/\D/","",$raw)).
 " normalized_digits=".strlen($norm)." valid=".(preg_match("/^09[0-9]{9}$/D",$norm)?"yes":"no").PHP_EOL;
 if (!preg_match("/^09[0-9]{9}$/D",$norm)) exit(12);
}
echo "DIGIPAY_PHONE_COMPAT_TESTS_OK\n";
' 2>&1 | tail -22
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --max-time 45 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "AFTER $path status=$code"
  [[ "$code" == 200 ]] || exit 13
done
if docker logs --since 2m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error.*vc-vesta-digipay-mobile|Uncaught .*vc-vesta-digipay-mobile'; then exit 14; fi
applied=no
trap - EXIT
echo "DIGIPAY_PHONE_COMPAT_DEPLOY_SUCCESS"
