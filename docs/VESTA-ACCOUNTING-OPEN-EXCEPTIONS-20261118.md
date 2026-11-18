# Vesta accounting — open exception register (18 November 2026)

Source: merchant-supplied accounting dashboard list, cross-checked for the 24 recent orders against the production outbox read-back on 18 Nov 2026. Historical 103xxx statuses are from the dashboard supplied by the merchant, not newly independently scanned in this document. **This register does not mean Mahak Cloud or Windows documents were corrected.**

**Rows:** 100 (24 active/recent, 76 historical). This is the dashboard's latest 100 visible exceptions, **not the full historical backlog**. Never infer absence of all other exceptions. Duplicate invoice prevention and client identity must remain enforced. Amounts in Toman; no stock edits.

| Woo order | Outbox state | Failure reason | Mahak Cloud invoice ID shown | Origin |
|---:|---|---|---:|---|
| 105580 | blocked | `customer_erp_name_mismatch` | 0 | production readback |
| 105545 | blocked | `missing_product_mapping` | 0 | production readback |
| 105540 | uncertain | `submitted_without_remote_ack` | 0 | production readback |
| 105537 | blocked | `customer_erp_person_unmapped` | 0 | production readback |
| 105535 | uncertain | `submitted_without_remote_ack` | 0 | production readback |
| 105482 | uncertain | `submitted_without_remote_ack` | 0 | production readback |
| 105480 | blocked | `missing_product_mapping` | 0 | production readback |
| 105419 | uncertain | `submitted_without_remote_ack` | 0 | production readback |
| 105369 | uncertain | `submitted_without_remote_ack` | 0 | production readback |
| 105228 | cloud_mismatch | `missing_mapping` | 308745913 | production readback |
| 105227 | cloud_mismatch | `invoice_total_or_shipping` | 308745908 | production readback |
| 105226 | cloud_mismatch | `invoice_total_or_shipping` | 308745896 | production readback |
| 105225 | cloud_mismatch | `invoice_total_or_shipping` | 308745884 | production readback |
| 105223 | cloud_mismatch | `invoice_total_or_shipping` | 308745880 | production readback |
| 105221 | cloud_mismatch | `invoice_total_or_shipping` | 308745797 | production readback |
| 105220 | cloud_mismatch | `invoice_total_or_shipping` | 308745717 | production readback |
| 105219 | cloud_mismatch | `invoice_total_or_shipping` | 308745476 | production readback |
| 105208 | conflict | `local_ack_without_remote_invoice` | 308578979 | production readback |
| 105207 | cloud_mismatch | `line_quantity_or_amount` | 308578501 | production readback |
| 105206 | cloud_mismatch | `line_quantity_or_amount` | 308578449 | production readback |
| 105205 | cloud_mismatch | `line_quantity_or_amount` | 308578388 | production readback |
| 105204 | cloud_mismatch | `line_quantity_or_amount` | 308578335 | production readback |
| 105053 | cloud_mismatch | `line_quantity_or_amount` | 308578278 | production readback |
| 105052 | conflict | `local_ack_without_remote_invoice` | 308577938 | production readback |
| 103303 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103302 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103301 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103300 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103299 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103298 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103297 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103296 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103295 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103294 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103292 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103289 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103287 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103286 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103284 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103283 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103281 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103280 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103279 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103278 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103277 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103276 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103274 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103273 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103272 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103270 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103268 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103267 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103266 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103264 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103252 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103250 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103246 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103244 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103237 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103236 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103235 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103234 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103233 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103230 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103229 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103227 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103226 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103222 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103221 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103220 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103219 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103218 | blocked | `historical_ledger_export_required` | 0 | dashboard capture |
| 103216 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103215 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103213 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103212 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103211 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103210 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103209 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103208 | blocked | `customer_account_unassigned` | 0 | dashboard capture |
| 103207 | blocked | `customer_account_unassigned` | 0 | dashboard capture |
| 103195 | blocked | `customer_account_unassigned` | 0 | dashboard capture |
| 103180 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103179 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103176 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103174 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103173 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103172 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103171 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103168 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103167 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103163 | blocked | `customer_phone_owner_mismatch` | 0 | dashboard capture |
| 103161 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103159 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103157 | blocked | `customer_account_unassigned` | 0 | dashboard capture |
| 103156 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103155 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103152 | blocked | `missing_product_mapping` | 0 | dashboard capture |
| 103151 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |
| 103150 | blocked | `customer_erp_person_unmapped` | 0 | dashboard capture |

## Verified triage (not corrected)
- Woo #105545: missing Mahak product variant "دودی" for Woo variation 101738; available ERP detail records for parent good 10685229 are "آبی" and a null-property detail. Matching details not found; do not map to wrong shade.
- Woo #105480: missing "کد6" ERP detail for Woo variation 52855; existing details under ERP good 10685552 are "کد5" and a null-property detail.
- Woo #105228: order line uses Woo variable parent 42714 and the ERP invoice's product detail 12182833 says "کد6"; line variant identity requires unambiguous order-item evidence before mapping.
- Woo #105580/#105537: OTP phone owner is the customer account, but profile name does not match billing name and no cloud Person matches exact name + phone, so account-to-ERP relinking would be unsafe.
- All 5 'uncertain' records were previously submitted. All seven no-ACK/conflict records have **zero** exact cloud client-ID matches in full current cloud ledger. This is **not** definitive proof that no Mahak Windows invoice exists. Do not re-submit without a complete desktop fiscal-year ledger and bank/receipt reconciliation.
- Existing cloud mismatch scan checked 912 invoices, finding zero that satisfied exact item/amount/bank/identity re-verification under multiplier 1 or 10. Do not bulk mark as verified.
- Two known Mahak Windows line-price discrepancies: desktop invoice 34 vs Woo 105429 (4,950,000 excess); invoice 42 vs Woo 105225 (891,000 line overcharge offset by 150,000 missing shipping = 741,000 balance overstatement). Both need audited Windows correction, not Woo or cloud duplicates.

### Evidence
- [Current 24-order readback](https://github.com/hsdarestani/vestacutella/actions/runs/44337065431)
- [ERP cloud person strict check](https://github.com/hsdarestani/vestacutella/actions/runs/44337955912)
- [No-ACK full cloud-ledger lookup](https://github.com/hsdarestani/vestacutella/actions/runs/44338314820)
- [Existing cloud mismatch verification](https://github.com/hsdarestani/vestacutella/actions/runs/44334209110)
- [Master remediation issue #9](https://github.com/hsdarestani/vestacutella/issues/9)

Status: **OPEN**. The table is an auditable exception inventory, not an accounting write-off or completed synchronization.