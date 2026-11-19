<?php
// New accounting epoch regression: no 2026 legacy invoice can be replayed.
require __DIR__.'/accounting-outbox-test.php';

class NewEpochOrder extends FakeOrder {
 function get_date_created(){return new DateTime('2026-11-20T00:00:00Z');}
}
reset_case(false,false);
$GLOBALS['options']['vcar_new_accounting_epoch']=[
 'epoch_utc'=>'2026-11-19T18:59:11Z',
 'last_legacy_order_id'=>2,
 'state'=>'waiting_for_new_mahak_company_and_opening_stock'
];
$GLOBALS['options']['vcar_new_accounting_target_ready']=false;
// Sender enabled intentionally to prove the target-ready guard blocks writes.
$GLOBALS['options']['vcar_sender_enabled']=true;
ensure(!Vesta_Accounting_Reliability::cutover_allows_order(1,new FakeOrder(1)),
 'pre_cutover_order_id_one_never_allowed');
ensure(!Vesta_Accounting_Reliability::cutover_allows_order(2,new FakeOrder(2)),
 'cutoff_order_never_allowed');
ensure(!Vesta_Accounting_Reliability::cutover_allows_order(3,new FakeOrder(3)),
 'backdated_post_cutoff_id_never_allowed');
ensure(Vesta_Accounting_Reliability::cutover_allows_order(3,new NewEpochOrder(3)),
 'new_order_with_new_id_and_new_timestamp_allowed');
Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===0,'legacy_outbox_not_submitted_after_new_epoch');
ensure(Vesta_Accounting_Reliability::epoch_min_order()===2,'epoch_cutoff_persists');
