<?php
/**
 * Backfill all admin-visible orders from the known SMTP outage.
 *
 * Mail logs are SMTP-level; they cannot reliably associate individual delivery
 * failures with order IDs. Send one daily recovery digest rather than hundreds
 * of potentially duplicated original new-order notifications.
 *
 * No emails are sent to customers, and no order records are changed.
 */
if (PHP_SAPI !== 'cli') { exit(90); }
require '/var/www/html/wp-load.php';
if (!function_exists('wc_get_order') || !function_exists('WC')) { fwrite(STDERR, "NO_WOOCOMMERCE\n"); exit(11); }
global $wpdb;

$cfg = get_option('wp_mail_smtp', array());
$s = isset($cfg['smtp']) ? (array) $cfg['smtp'] : array();
if (($s['host'] ?? '') !== 'server135s.irwebspace.com' || (int)($s['port'] ?? 0) !== 587 || ($s['encryption'] ?? '') !== 'tls') {
    fwrite(STDERR, "SECURE_SMTP_PREFLIGHT_FAILED\n"); exit(12);
}
$email = null;
foreach (WC()->mailer()->get_emails() as $e) {
    if (isset($e->id) && $e->id === 'new_order') { $email = $e; break; }
}
if (!$email || !method_exists($email, 'is_enabled') || !$email->is_enabled()) {
    fwrite(STDERR, "ADMIN_ORDER_EMAIL_DISABLED\n"); exit(13);
}
$recipients = array_values(array_filter(array_map('trim', explode(',', (string)$email->get_recipient())), 'is_email'));
if (count($recipients) !== 1 || strpos($recipients[0], '@gmail.com') === false) {
    // Don't risk sending to unknown/additional recipients.
    fwrite(STDERR, "UNEXPECTED_ORDER_RECIPIENT_CONFIG\n"); exit(14);
}
echo "RECOVERY_RECIPIENT_CONFIRMED count=1 domain=gmail.com\n";
$t = $wpdb->prefix . 'wc_orders';
if ($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s", $t)) !== $t) {
    fwrite(STDERR, "HPOS_ORDER_TABLE_MISSING_ABORT\n"); exit(15);
}
$allowed = array('wc-pending', 'wc-processing', 'wc-completed', 'wc-on-hold', 'wc-failed', 'wc-cancelled', 'wc-refunded');
$first = '2026-10-11';
$last = '2026-10-19';
$finalCutoff = '2026-10-19 13:48:00'; // SMTP repair passed at 13:48:12 UTC
$dry = isset($argv[1]) && $argv[1] === '--dry-run';
$send = isset($argv[1]) && $argv[1] === '--send';
if (!$dry && !$send) { fwrite(STDERR, "USAGE_DRY_RUN_OR_SEND\n"); exit(16); }
$errors = 0;
$accepted = 0;
$totalListed = 0;
$totalAlreadyReplayed = 0;
$range = new DatePeriod(new DateTimeImmutable($first, new DateTimeZone('UTC')), new DateInterval('P1D'), (new DateTimeImmutable($last, new DateTimeZone('UTC')))->modify('+1 day'));
foreach ($range as $date) {
    $day = $date->format('Y-m-d');
    $end = $date->modify('+1 day')->format('Y-m-d') . ' 00:00:00';
    $start = $day . ' 00:00:00';
    if ($day === $last) $end = $finalCutoff;
    $ids = $wpdb->get_col($wpdb->prepare(
        "SELECT id FROM {$t} WHERE type='shop_order' AND date_created_gmt >= %s AND date_created_gmt < %s AND status IN ('wc-pending','wc-processing','wc-completed','wc-on-hold','wc-failed','wc-cancelled','wc-refunded') ORDER BY date_created_gmt ASC, id ASC LIMIT 700",
        $start, $end
    ));
    $rows = array();
    foreach ($ids as $id) {
        $order = wc_get_order((int)$id);
        if (!$order) continue;
        $status = 'wc-' . $order->get_status();
        if (!in_array($status, $allowed, true)) continue;
        $time = $order->get_date_created();
        // Use the persisted order's public number, status and total; no client addresses.
        $number = sanitize_text_field((string)$order->get_order_number());
        $total = strip_tags(wc_price($order->get_total(), array('currency' => $order->get_currency())));
        $total = html_entity_decode($total, ENT_QUOTES | ENT_HTML5, 'UTF-8');
        $url = method_exists($order, 'get_edit_order_url') ? $order->get_edit_order_url() : admin_url('admin.php?page=wc-orders&action=edit&id=' . (int)$id);
        $rows[] = '#'.$number.' | '.($time ? $time->date('Y-m-d H:i') : $day).' | '.$order->get_status().' | '.$total."\n".$url;
    }
    $n = count($rows);
    $totalListed += $n;
    $key = 'vc_vesta_admin_order_outage_digest_20261019_' . str_replace('-', '', $day);
    $previous = get_option($key, false);
    echo "BACKFILL_DAY day=$day listed=$n already_accepted=".($previous ? 'yes':'no')."\n";
    if ($dry || !$n || $previous) {
        if ($previous) ++$totalAlreadyReplayed;
        continue;
    }
    $subject = 'Vesta | بازیابی اعلان سفارش‌ها | ' . $day . ' | ' . $n . ' سفارش';
    $body =
        "گزارش بازیابی اعلان‌های سفارش‌های وستا\n\n".
        "تاریخ ثبت (UTC): ".$day."\n".
        "تعداد سفارش‌های این روز: ".$n."\n\n".
        "به‌دلیل مشکل SMTP در بازه ۱۱ تا ۱۹ اکتبر، نمی‌توان از لاگ‌ها تشخیص داد اعلان کدام سفارش قطعاً به مقصد نرسیده است. ".
        "بنابراین این گزارش همه سفارش‌های ثبت‌شده در بازه اختلال را پوشش می‌دهد و فقط برای مدیر فروشگاه ارسال شده است، نه مشتریان.\n".
        "توجه: سفارش‌های لغوشده، ناموفق و در انتظار هم برای جلوگیری از جاافتادن سفارش در این گزارش آمده‌اند.\n\n".
        implode("\n\n", $rows).
        "\n\nاین ایمیل یک گزارش بازیابی است و سفارش تازه‌ای ایجاد نشده است.\n";
    $failure = null;
    $onFailure = function($error) use (&$failure) {
        $message = strtolower((string)$error->get_error_message());
        $failure = strpos($message,'auth') !== false ? 'authentication' : (strpos($message,'connect') !== false ? 'connection' : 'other');
    };
    add_action('wp_mail_failed', $onFailure, 10, 1);
    $ok = wp_mail($recipients, $subject, $body, array('Content-Type: text/plain; charset=UTF-8'));
    remove_action('wp_mail_failed', $onFailure, 10);
    if (!$ok) {
        echo "BACKFILL_MAIL_REJECTED day=$day category=".($failure ?: 'unknown')."\n";
        ++$errors;
        break; // Never hammer an unresponsive mail server.
    }
    // Mark only SMTP-accepted digests. Retry of this workflow will skip them.
    add_option($key, array('utc'=>gmdate('c'), 'count'=>$n, 'range'=>$day, 'kind'=>'admin_digest'), '', 'no');
    echo "BACKFILL_SMTP_ACCEPTED day=$day count=$n\n";
    ++$accepted;
    // Avoid mail rate spikes; these are only 9 grouped digest messages.
    usleep(1100000);
}
echo "BACKFILL_SUMMARY mode=".($dry?'dry_run':'send')." orders_listed=$totalListed day_emails_accepted=$accepted previous_days=$totalAlreadyReplayed errors=$errors\n";
if ($errors) exit(22);
echo "VESTA_ORDER_OUTAGE_DIGEST_BACKFILL_COMPLETE\n";
