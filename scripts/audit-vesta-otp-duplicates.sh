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
// Audit ambiguous billing-only groups without disclosing any personal data.
$detail=array(
  'ambiguous_groups_with_no_order_owners'=>0,
  'ambiguous_groups_with_one_order_owner'=>0,
  'ambiguous_groups_with_multiple_order_owners'=>0,
  'ambiguous_groups_with_missing_email'=>0,
  'groups_with_unusual_stored_phone_forms'=>0
);
foreach ($groups as $phone=>$g) {
  $variants=array($phone,'+98'.substr($phone,1),'98'.substr($phone,1),
    substr($phone,1),'0098'.substr($phone,1));
  foreach ($rows as $r) {
    if (vesta_otp_phone((string)$r['meta_value'])===$phone &&
        !in_array((string)$r['meta_value'],$variants,true)) {
      ++$detail['groups_with_unusual_stored_phone_forms'];
      break;
    }
  }
  if (count($g['all'])<2 || count($g['login'])!==0) continue;
  $with_orders=0; $without_email=false;
  foreach (array_keys($g['all']) as $uid) {
    $user=get_user_by('id',$uid);
    if (!$user || !is_email($user->user_email)) $without_email=true;
    if (function_exists('wc_get_orders')) {
      $ids=wc_get_orders(array('customer_id'=>$uid,'limit'=>1,'return'=>'ids'));
      if (!empty($ids)) ++$with_orders;
    }
  }
  if ($with_orders===0) ++$detail['ambiguous_groups_with_no_order_owners'];
  elseif ($with_orders===1) ++$detail['ambiguous_groups_with_one_order_owner'];
  else ++$detail['ambiguous_groups_with_multiple_order_owners'];
  if ($without_email) ++$detail['ambiguous_groups_with_missing_email'];
}
echo 'OTP_AUDIT_DETAILS='.wp_json_encode($detail)."\n";
echo 'OTP_AUDIT_SUMMARY='.wp_json_encode($stats)."\n";
echo "OTP_AUDIT_COMPLETE=read_only\n";
PHP
