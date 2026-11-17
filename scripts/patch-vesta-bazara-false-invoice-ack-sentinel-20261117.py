#!/usr/bin/env python3
"""Surgical vendor patch: never write shared fake invoice ID on protected sender path.

The outbox reserved 'sending' state BEFORE this handler runs. If Bazara
cannot independently confirm the Orders result, the outbox will preserve
an uncertain record and never auto-replay without remote ledger proof.

Legacy/non-protected callers retain their old no-replay sentinel behavior
until their own replacement guard is verified separately.
"""
from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch.py existing_vendor_php destination_php")

source=Path(sys.argv[1]).read_text(encoding="utf-8")
old="""        if (!$orderError) {
            if (!$hpos_enable) {
                update_post_meta($oid, 'mahak_id', '54323444');
            } else {
                // HPOS
                $order_hpos = wc_get_order($oid);
                $order_hpos->update_meta_data('mahak_id', '54323444');
                $order_hpos->save();
            }
        }"""
new="""        if (!$orderError) {
            // In the Vesta protected accounting sender, an absent ERP Orders
            // acknowledgement is uncertain, NOT an invoice with a made-up ID.
            // The durable outbox reserved submission first, and alone decides
            // whether recheck or replay can ever be safe. Other legacy callers
            // retain the vendor's old stop-marker until separately reviewed.
            if (class_exists('Vesta_Accounting_Reliability') &&
                Vesta_Accounting_Reliability::$dispatching) {
                if (!$hpos_enable) {
                    update_post_meta($oid, '_vcar_vendor_missing_order_ack', gmdate('c'));
                } else {
                    $order_hpos = wc_get_order($oid);
                    $order_hpos->update_meta_data('_vcar_vendor_missing_order_ack', gmdate('c'));
                    $order_hpos->save();
                }
            } else {
                if (!$hpos_enable) {
                    update_post_meta($oid, 'mahak_id', '54323444');
                } else {
                    // HPOS legacy fallback: never automatically replay.
                    $order_hpos = wc_get_order($oid);
                    $order_hpos->update_meta_data('mahak_id', '54323444');
                    $order_hpos->save();
                }
            }
        }"""
if source.count(new)==1:
    print("BAZARA_PROTECTED_FAKE_ACK_GUARD_ALREADY_PRESENT=yes")
    Path(sys.argv[2]).write_text(source, encoding="utf-8")
    raise SystemExit(0)
if source.count(old)!=1:
    raise SystemExit("ABORT: expected exact unique vendor source sentinel block not found")
out=source.replace(old,new,1)
if out.count("update_post_meta($oid, 'mahak_id', '54323444');")!=1:
    raise SystemExit("ABORT: unexpected legacy sentinel count")
if out.count("_vcar_vendor_missing_order_ack")!=2:
    raise SystemExit("ABORT: protected uncertainty marker not present in both HPOS paths")
Path(sys.argv[2]).write_text(out, encoding="utf-8")
print("BAZARA_PROTECTED_FAKE_ACK_GUARD_STAGED_EXACTLY_ONE_BLOCK=yes")
print("LEGACY_NONOUTBOX_COMPATIBILITY_UNCHANGED=yes")
