<?php
/**
 * Vesta accounting identity checks.
 * Protects live ERP against misattribution from stale Woo customer IDs,
 * cached generic Mahak person IDs and late account association.
 * This module never creates users/persons/orders or modifies financial data.
 */
if (!function_exists('vcar_identity_normalize_name')) {
    function vcar_identity_normalize_name($text) {
        $text = str_replace(array('ي','ك','ة',"\xE2\x80\x8C"), array('ی','ک','ه',' '), (string)$text);
        return trim((string)preg_replace('/\s+/u', ' ', $text));
    }
}
if (!function_exists('vcar_identity_guard')) {
    function vcar_identity_guard($order, $remotePersonId = null) {
        // Test doubles without WordPress/Woo APIs are independently checked by policy tests.
        if (!function_exists('get_user_by') || !function_exists('get_user_meta') ||
            !method_exists($order, 'get_customer_id') || !method_exists($order,'get_billing_phone')) return '';
        $uid = (int)$order->get_customer_id();
        if ($uid <= 0) return 'customer_account_unassigned';
        $u = get_user_by('id', $uid);
        if (!$u || empty($u->ID)) return 'customer_account_missing';
        $roles=(array)($u->roles??array());
        if (array_intersect($roles,array('administrator','shop_manager','editor','author'))) return 'customer_account_privileged';
        if (!array_intersect($roles,array('customer','subscriber'))) return 'customer_account_invalid_role';

        $rawPhone = trim((string)$order->get_billing_phone());
        $hasPhone = $rawPhone !== '';
        $customerContactVerified = false;
        if ($hasPhone) {
            if (!function_exists('vesta_otp_phone') || !function_exists('vesta_otp_existing_user')) return 'customer_phone_adapter_unavailable';
            $phone = vesta_otp_phone($rawPhone);
            if (!$phone) return 'customer_billing_phone_invalid';
            $owner = vesta_otp_existing_user($phone);
            if ((function_exists('is_wp_error') && is_wp_error($owner)) || !is_numeric($owner) || (int)$owner !== $uid)
                return 'customer_phone_owner_mismatch';
            $customerContactVerified = true;
        }
        if (!$customerContactVerified) {
            $email=strtolower(trim((string)$order->get_billing_email()));
            $emailUser=$email ? get_user_by('email',$email) : false;
            if (!$emailUser || (int)$emailUser->ID!==$uid) return 'customer_contact_unverified';
        }
        $billing=vcar_identity_normalize_name($order->get_billing_first_name().' '.$order->get_billing_last_name());
        if ($billing==='') return 'customer_billing_name_missing';

        $personId=(int)get_user_meta($uid,'mahak_id',true);
        if ($personId<=0) return 'customer_erp_person_unmapped';
        if ($remotePersonId !== null && (int)$remotePersonId !== $personId) return 'customer_remote_person_mismatch';

        // Person cache is a necessary but not sufficient proof: verify both id and name.
        global $wpdb;
        if (!isset($wpdb) || !is_object($wpdb) || !method_exists($wpdb,'get_row') ||
            !method_exists($wpdb,'prepare') || empty($wpdb->prefix)) return 'customer_person_cache_unavailable';
        $table=$wpdb->prefix.'bazara_persons';
        $row=$wpdb->get_row($wpdb->prepare(
            "SELECT FirstName,LastName FROM $table WHERE PersonId=%d AND Deleted=0 LIMIT 1", $personId
        ));
        if (!$row) {
            // The vendor local cache can lag behind a confirmed cloud person registration.
            // Accept ONLY a person ID/name proof recorded after direct cloud readback.
            $proofId=(int)get_user_meta($uid,'_vesta_erp_cloud_verified_person_id',true);
            $proofName=vcar_identity_normalize_name(get_user_meta($uid,'_vesta_erp_cloud_verified_person_name',true));
            if ($proofId!==$personId || $proofName==='' || $proofName!==$billing) return 'customer_erp_person_not_found';
        } else {
            $erpName=vcar_identity_normalize_name(($row->FirstName??'').' '.($row->LastName??''));
            if ($erpName==='' || $erpName!==$billing) return 'customer_erp_name_mismatch';
        }

        return '';
    }
}
