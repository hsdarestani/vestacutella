<?php
// Pure verification policy. No writes and no customer data in diagnostic reasons.
function vcar_definite_rollback($raw) {
    if(!is_string($raw))return false;
    $outer=json_decode($raw,true);$candidates=array();
    if(is_array($outer)){
        $candidates[]=$outer;
        if(isset($outer['message'])&&is_string($outer['message']))$candidates[]=json_decode($outer['message'],true);
    }
    // Vendor writes nested JSON via update_post_meta without wp_slash; recover only the JSON envelope.
    if(preg_match('/"message":"(.*)"\s*}$/s',$raw,$m))$candidates[]=json_decode($m[1],true);
    foreach($candidates as $r){
        if(!is_array($r)||!array_key_exists('Result',$r)||$r['Result']!==false||!is_string($r['Message']??null))continue;
        // SQL Server 1205 explicitly rolls back its victim; generic timeouts/rejections remain ambiguous.
        if(preg_match('/^Transaction \(Process ID [0-9]+\) was deadlocked on .+ resources with another process and has been chosen as the deadlock victim\.\s*Rerun the transaction\.?$/i',trim($r['Message'])))return true;
    }
    return false;
}
function vcar_eligible($o) {
    return $o && $o->get_date_paid() && $o->has_status(array_unique(array_merge(
        wc_get_is_paid_statuses(), array('processing5','pws-packaged','pws-shipping','arrival-shipment','pws-courier','pws-post')
    )));
}
function vcar_bank($settings, $method) {
    $rows = json_decode(stripslashes($settings['banksMethods'] ?? ''), true);
    $ids = array();
    foreach (is_array($rows) ? $rows : array() as $r) {
        if (($r['method'] ?? '') === $method) $ids[] = (int)($r['name'] ?? 0);
    }
    return count($ids) === 1 && $ids[0] > 0 ? $ids[0] : 0;
}
function vcar_verify($order, $row, $lines, $receipts, $bank, $transfers=array()) {
    if (!empty($row['Deleted']) || (int)($row['OrderClientId'] ?? 0) !== (int)$order->get_id()) return 'remote_identity';
    if ($order->get_currency() !== 'IRT') return 'unsupported_currency';
    if ((float)$order->get_total_tax() != 0 || count($order->get_items('fee'))) return 'unsupported_tax_or_fee';
    $expected = array();
    foreach ($order->get_items('line_item') as $item) {
        $pid = $item->get_variation_id() ?: $item->get_product_id();
        $detail = (int)get_post_meta($pid, 'mahak_product_detail_id', true);
        $product = (int)get_post_meta($pid, 'mahak_id', true);
        if (!$detail || !$product) return 'missing_mapping';
        $k = (string)$detail;
        if (!isset($expected[$k])) $expected[$k] = array(0,0);
        $expected[$k][0] += (float)$item->get_quantity();
        $expected[$k][1] += (float)$item->get_total() * 10;
    }
    $actual = array(); $sum = 0;
    foreach ($lines as $line) {
        if (!empty($line['Deleted'])) continue;
        $k = (string)(int)($line['ProductDetailId'] ?? 0);
        $qty = (float)($line['Count1'] ?? 0);
        $net = (float)($line['Price'] ?? 0) * $qty - (float)($line['Discount'] ?? 0);
        if (!isset($actual[$k])) $actual[$k] = array(0,0);
        $actual[$k][0] += $qty; $actual[$k][1] += $net; $sum += $net;
    }
    if (count($actual) !== count($expected)) return 'line_identity';
    foreach ($expected as $key=>$v) {
        if (!isset($actual[$key]) || abs($v[0]-$actual[$key][0]) > 0.00001 || abs($v[1]-$actual[$key][1]) > 0.51) return 'line_quantity_or_amount';
    }
    $shipping = (float)($row['SendCost'] ?? 0);
    if (abs($shipping - (float)$order->get_shipping_total()*10) > 0.51 ||
        abs($sum - (float)($row['Discount'] ?? 0) + $shipping - (float)$order->get_total()*10) > 0.51) return 'invoice_total_or_shipping';
    $active = array_values(array_filter($receipts, function($r){return empty($r['Deleted']);}));
    if (count($active) !== 1) return count($active) ? 'multiple_receipts' : 'missing_receipt';
    $r = $active[0];
    // SaveAllData links the receipt through Receipts.OrderId; Orders.ReceiptId may remain null.
    if ((int)($r['OrderId']??0)!==(int)($row['OrderId']??0) || (int)($row['OrderId']??0)<=0 ||
        (!empty($row['ReceiptId']) && (int)$row['ReceiptId']!==(int)($r['ReceiptId']??0))) return 'receipt_link';
    $transfers=array_values(array_filter($transfers,function($t)use($r){return empty($t['Deleted'])&&(int)($t['ReceiptId']??0)===(int)$r['ReceiptId'];}));
    if(count($transfers)!==1)return count($transfers)?'multiple_bank_transfers':'bank_transfer_unverified';
    $t=$transfers[0];
    if((int)($t['Type']??0)!==2)return 'receipt_transfer_type';
    if (!$bank || (int)($t['BankId']??0) !== $bank) return 'receipt_bank';
    if (!isset($t['Amount']) || abs((float)$t['Amount']+(float)($r['CashAmount']??0) - (float)$order->get_total()*10) > 0.51) return 'receipt_amount';
    return '';
}
