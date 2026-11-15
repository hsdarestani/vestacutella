# Vesta automatic customer panels — 2026-11-15

Production is enabled. Confirmed WooCommerce purchases from Shopino, TorobPay, SnappPay, Zibal and other channels now create or reuse a customer account and attach the order to its panel.

## Verified outcome

Read-back at 18:07 UTC / 21:37 Tehran:
- 57 previously guest, confirmed current-month orders attached and independently checked against the SMS login identity.
- Shopino: 38; TorobPay: 7; SnappPay: 6; Zibal: 6.
- All 163 confirmed current-month orders across the six observed payment gateways have a customer account. Remaining confirmed guest orders: zero. Remaining account issues: zero.
- New account/order association is idempotent and does not merge users or replace existing order customer assignments.
- Woo customer-panel queries return each associated real order. OTP resolution selects the same user.
- Pending/failed/cancelled/draft purchases are not treated as completed purchases. Confirmation hooks handle payment completion later.
- The observed 098 + complete 10-digit national mobile export format is normalized without guessing missing digits. Order 103272 is linked; its original billing phone and financial fields were preserved.
- Existing accounting currency remains toman/toman. Accounting code hashes were unchanged. Per-order money, shipping, discounts, status, contacts and financial references were checked during attachment.
- Public home and account pages returned 200; empty checkout returned its expected 302.

## Implementation

- MU plugin: `infra/plugins/vesta-channel-customers/vesta-channel-customers.php`.
- Shared phone creation/identity lock: `vesta_otp_resolve_customer()` in the existing active SMS login plugin. It creates customer-role accounts, not authenticated sessions.
- Hooks cover ordinary and block checkout, REST/API order saves, payment completion and order status changes. Partial imports wait for a confirmed order with line items and usable contact information.
- Existing explicit phone ownership and duplicate-contact recovery rules are retained. Privileged accounts are rejected. Conflicting email/phone identities and missing/invalid contacts are flagged in order administration; no identity or email is invented.
- Phone-only customers use the existing SMS OTP form at https://vesta-cosmetics.ir/my-account/ . Email-only customers use their real email and the existing password recovery flow.
- No checkout login requirement or optional-registration setting was changed. Imported purchases are covered by the order lifecycle.
- Bounded retry worker every five minutes: `/etc/cron.d/vesta-channel-customers`, `scripts/vesta-channel-customer-worker.php`. Service is active and final retry results are empty.
- Feature flag: `vesta_channel_accounts_enabled`.
- Backfill/retry lower bound: `vesta_channel_accounts_since` = 2026-11-01 00:00 UTC. Earlier history was not bulk modified.
- Audit metadata: `_vesta_account_linked_at` and `_vesta_account_issue`. Existing customer profile data is not overwritten.

## Validation and evidence

- 32 isolated identity, gateway, normalization, failure and order-lifecycle regression assertions passed.
- Production PHP 7.4 syntax checks and real-order panel canaries passed.
- Complete mocked OTP send, verification, registration, duplicate-phone protection and dual email/SMS recovery passed in an isolated database. No real SMS/email was sent by the tests.
- Staging was corrected to unlink replaced hardlinked files and isolate its object cache, database transients, HTTP and mail.
- Deployment: https://github.com/hsdarestani/vestacutella/actions/runs/43744139321
- Observed-prefix normalization and last real-order verification: https://github.com/hsdarestani/vestacutella/actions/runs/43744813271
- Complete final OTP suite: https://github.com/hsdarestani/vestacutella/actions/runs/43744813286
- Final coverage and retry read-back: https://github.com/hsdarestani/vestacutella/actions/runs/43744941702

## Operations

A private verified pre-deployment SQL/code backup is at `/srv/backups/vesta-channel-accounts-20261115T175937Z`. Earlier deployment backups and a separate prefix patch backup are also retained on the server.

If rollback is needed, disable the feature flag and worker, then restore compatible plugin code. Preserve created accounts and valid order/customer links. Never restore user/order databases wholesale after new purchases.

Future orders with genuinely missing, ambiguous or invalid identity information require correction and remain visibly flagged. The implementation does not promise to invent missing customer information or resolve account-ownership conflicts automatically.
