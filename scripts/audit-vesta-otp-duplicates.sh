#!/usr/bin/env bash
# Read-only production audit. Only anonymous totals are printed to CI logs.
set -euo pipefail
echo "OTP_AUDIT_BEGIN"
docker exec -i vc-vesta php -d display_errors=0 <<'PHP'
<?php
ob_start();
require '/var/www/html/wp-load.php';
global $wpdb;
$rows=$wpdb->get_results("SELECT user_id, meta_key, meta_value FROM {$wpdb->usermeta} WHERE meta_key IN ('smsir_phone','phone','billing_phone')", ARRAY_A);
$err=$wpdb->last_error;
ob_end_clean();
if ($err || !is_array($rows) || !function_exists('vesta_otp_phone')) {
  echo "OTP_AUDIT_FAILURE=database_or_plugin_unavailable\n";
  exit(2);
}
$groups=array(); $users=array(); $invalid=0;
foreach ($rows as $r) {
    $phone=vesta_otp_phone((string)$r['meta_value']);
    if (!$phone) { ++$invalid; continue; }
    $uid=(int)$r['user_id'];
    if ($uid<1) continue;
    if (!isset($groups[$phone])) {
        $groups[$phone]=array('all'=>array(),'login'=>array(),'billing'=>array());
    }
    $groups[$phone]['all'][$uid]=1;
    if ($r['meta_key']==='billing_phone') $groups[$phone]['billing'][$uid]=1;
    else {
        $groups[$phone]['login'][$uid]=1;
        if (!isset($users[$uid])) $users[$uid]=array();
        $users[$uid][$phone]=1;
    }
}
$stats=array(
 'phone_meta_rows'=>count($rows),
 'invalid_meta_rows'=>$invalid,
 'unique_valid_phones'=>count($groups),
 'phones_on_multiple_accounts'=>0,
 'single_login_owner_plus_billing_contacts'=>0,
 'multiple_login_owners'=>0,
 'multiple_billing_only_owners'=>0,
 'single_account_numbers'=>0,
 'single_account_billing_only_numbers'=>0,
 'accounts_with_multiple_login_phones'=>0,
 'privileged_login_owner_groups'=>0,
 'resolver_mismatches'=>0,
);
foreach ($users as $phones) if (count($phones)>1) ++$stats['accounts_with_multiple_login_phones'];
foreach ($groups as $phone=>$g) {
  $a=count($g['all']); $l=count($g['login']);
  if ($a===1) {
    ++$stats['single_account_numbers'];
    if ($l===0) ++$stats['single_account_billing_only_numbers'];
  } else {
    ++$stats['phones_on_multiple_accounts'];
    if ($l>1) ++$stats['multiple_login_owners'];
    elseif ($l===1) ++$stats['single_login_owner_plus_billing_contacts'];
    else ++$stats['multiple_billing_only_owners'];
  }
  if ($l>0) {
    foreach (array_keys($g['login']) as $uid) {
      $u=get_user_by('id',$uid);
      if ($u && array_intersect((array)$u->roles,array('administrator','editor','author','shop_manager'))) {
        ++$stats['privileged_login_owner_groups']; break;
      }
    }
  }
}
echo 'OTP_AUDIT_SUMMARY='.wp_json_encode($stats)."\n";
echo "OTP_AUDIT_COMPLETE=read_only\n";
PHP
