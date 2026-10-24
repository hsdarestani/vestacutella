# VestaCutella production infrastructure

Infrastructure for the original WooCommerce stores vesta-cosmetics.ir and cutellashop.ir, and the isolated app.vesta-cosmetics.ir route.

## Storage
- /srv/vestacutella/repo: Git checkout and Docker config
- /srv/vestacutella/runtime/vesta and runtime/cutella: WordPress and image uploads
- /srv/vestacutella/runtime/db-vesta and runtime/db-cutella: separate MariaDB databases
- /srv/vestacutella/runtime/certs: certificates
- /srv/backups: timestamped rollback copies

Never commit WordPress uploads, databases, passwords, secrets, tokens or .env.

## Current optimizations (October 2026)

Both WordPress stores use WP Rocket, MariaDB, Nginx and Redis. Redis has no public listening port, a 128 MB cache memory ceiling, and a 192 MB container memory limit. Cutella uses Redis database 0, key prefix vc_cutella:. Vesta uses Redis database 1, key prefix vc_vesta:. Redis is linked using Predis, not a PHP extension.

Cutella uses a strictly cookie-free, no-query, GET/HEAD-only 12-second Nginx microcache for the homepage and /shop/. Stale content can be served while an asynchronous refresh is under way. Checkout, cart, account, admin, API, login and every request with cookies bypass the microcache. Never add those dynamic routes to a public edge cache.

Nine heavy Vesta homepage images (eight PNG and one JPEG) now have WebP sidecar alternatives ending in .vc20261014.webp. The originals remain intact as fallback. The Vesta hero must-use plugin integrates the four original heroes and five secondary images into picture/source elements. Deploy Vesta hero WebP safely and Deploy Vesta secondary WebP safely were run successfully on October 14; do not rerun them on the already deployed server.

The Nginx config includes independent HTTPS and reverse-proxy routing for app.vesta-cosmetics.ir; do not replace it with an outdated version missing that route. Because it is single-file Docker bind mounted, the deployment workflow recreates only vc-nginx and verifies the host and container configuration checksums.

Vesta still runs PHP 7.4 with ionCube and older plugins; do not upgrade PHP directly in production without testing plugin compatibility in staging.

## CDN findings and open dependency

On 14 October 2026, the public Cutella domain was proxied by Cloudflare. Its HTML was DYNAMIC at the edge, intentionally keeping shopping sessions fresh; static images were cacheable. Public Vesta served through Nginx directly rather than a Cloudflare edge. There is no connected Cloudflare account or deployment credential in this repo, so zone-specific DNS or CDN Cache Rules must be changed only after appropriate account authorization, verifying mail MX and all subdomains.

## Verification

The Live capacity audit workflow checks the front page and shop images including srcset variants, login/cart/checkout/account GET responses, Cookie-based cache bypass, Redis separation and Nginx syntax. Public mobile Lighthouse performance captures external mobile page load measurements. These probes do not place purchases, send OTP messages or validate real payment callbacks.

All production edits must have backups, smoke tests and automated rollback. Avoid deleting WooCommerce orders, scheduled-action records, sessions or images in the name of speed.

## Latest read-only browser QA (October 14, 2026)

The Storefront browser regression smoke workflow successfully checked anonymous home/shop/cart/checkout/account/login flows and a real product page (price, title, add-to-cart presence) on each store. It also reached the isolated Vesta app. No browser JavaScript errors or HTTP 5xx were found. Checkout redirects to cart when the test cart is empty; tests did not create customer orders, process real payments, verify OTP/SMS or authenticate users.

The Cutella guest Dashicons opt-out experiment failed an execution preflight and was fully reverted, with no must-use test plugin left in production. A separate read-only health check confirmed both stores, app, databases and Redis remained up. Do not treat that attempted opt-out as deployed.

Vesta mobile baseline CLS was 0.85 from Woodmart Owl initialization. On October 14 a narrowly scoped mobile-only CSS rule for preinitialized Owl carousels was successfully deployed via a guarded workflow; an independent cold browser verification on production measured CLS 0.3825, all 14 carousels initialized, 151 product cards present, 13 WebP picture sources visible and zero page JS exceptions. It did not require restarting any Docker container. The earlier broad visibility guard had no effect and was reverted. Static image and origin cache improvements do not imply Core Web Vitals pass. Do not remove interactive sliders or globally defer critical JS without a proven low-risk browser A/B win. Cutella still incurs render-blocking CSS; Revolution Slider and other WordPress frontend dependencies must be validated before removing assets.

Public Cutella uses Cloudflare, while Vesta remains directly on Nginx. Neither DNS nor Cloudflare zone Cache Rules were modified, because repository access does not establish authorization for the Cloudflare zone and unreviewed DNS changes can affect email, payment callbacks and the Vesta app.

## Additional tested mobile rendering optimization (14 October 2026)

On the Vesta homepage only, mobile devices receive a very narrow `content-visibility:auto;contain-intrinsic-size:auto 250px` rule on the 152 Woodmart carousel `.product-wrapper` nodes. The markup, prices, buttons, products, product pages, checkout and navigation are unchanged. The CSS is contained in the standalone runtime mu-plugin `vc-vesta-optimized-product-render.php`. It was validated with controlled cold Chromium mobile runs on GitHub Actions and then in the live browser. Three independent controlled variants with this selector showed lower long-task work than baseline (about one second in this lab); overall page scroll height changed by approximately two percent rather than the larger change with a 350px placeholder. All 14 carousels initialized, 152 cards and image fallback sources remained present, and scroll images loaded after entering the viewport.

Deployment: `.github/workflows/deploy-vesta-product-render.yml`; browser gate `scripts/verify-vesta-product-render.cjs`; rollback `scripts/revert-vesta-product-render.sh`. The workflow is intentionally idempotent. A preflight failure must never roll back a previously approved and installed optimization; rollback is conditional on that workflow run having successfully applied its own change.

The live browser regression test passed for home/shop/cart/checkout/account/login, sample product title/price/add-to-cart and the Vesta app, with zero critical errors after release. Real-world payment, OTP and full customer sessions are not covered by these read-only tests.

## Separate staging environment

See [staging and performance guide](docs/STAGING-AND-PERFORMANCE.md). The production server has about 3.9 GiB RAM with active swap and also hosts the Vesta app. Do not launch full cloned MariaDB/WordPress stacks there. The GitHub-hosted ephemeral mobile Chromium performance lab provides isolated frontend experimentation; a full transactional WooCommerce staging environment is **not provisioned** because it needs another independent host and sanitized test data.

## CDN and Cutella JS experiment outcomes (14 October 2026)

Read-only public DNS verified **both** vesta-cosmetics.ir and cutellashop.ir are delegated to Cloudflare nameservers `wanda.ns.cloudflare.com` and `cash.ns.cloudflare.com`. Cutella's public A resolves to Cloudflare edge IPs, with `server: cloudflare`. Vesta apex and `www` instead resolve directly to origin `193.177.242.64` and answer `server: nginx`; the app.vesta-cosmetics.ir hostname also resolves directly to that origin. No Cloudflare proxy or zone configuration was changed. The email MX is currently `mail.vesta-cosmetics.ir` (and `mail.cutellashop.ir` for Cutella). Only authorized Cloudflare operators should consider proxying storefront apex/www **after** verifying SSL, DNS-only mail records, app routes, login and payment callbacks.

Three in-browser experiments without the two Slider Revolution JS downloads found the custom Cutella hero and 30 product cards functional, but performance gains were variable. An anonymous-homepage-only WordPress plugin rollout was also attempted with automatic rollback, but the Cutella PHP CLI returned exit code 139; the plugin was removed by the rollback. Independent origin and real-browser tests afterwards confirmed both storefronts, app, Redis and Nginx healthy (zero browser-critical errors). The unverified Cutella deploy workflow and scripts were deleted to prevent an accidental re-run. **Do not retry the plugin approach on the live Cutella host until the PHP CLI crash is diagnosed in independent staging.**

Final post-Vesta-optimization Lighthouse in a single mobile lab run: Vesta 36/100 (LCP 4.0s, CLS 0.28), Cutella 56/100 (LCP 6.5s). Public Vesta origin response as measured externally remains ~3.9s in that run: CDN and network delivery remain important. These are single-run lab observations, not Core Web Vitals field averages.


## Independent Vesta order printing (17 October 2026)

The original Vesta WooCommerce invoice plugin `woocommerce-invoice-pro1` is installed and active, but its existing `wp-print` route shows a licence/domain-validation error in the owner's screenshots. **Do not edit the vendor's encoded/licensed code, spoof the licence, or silently disable the plugin.** Repairing the original plugin requires the authorised licence issuer to validate/rebind `https://vesta-cosmetics.ir`; a server migration is a possible cause, not a proven one.

A separate licence-free print flow was successfully deployed as a **must-use plugin** `wp-content/mu-plugins/vc-vesta-reliable-order-print.php` by [Deploy Vesta independent printing safely](.github/workflows/deploy-vesta-reliable-order-print.yml). Source: [standalone plugin](infra/plugins/vesta-reliable-order-print/vesta-reliable-order-print.php). In WooCommerce > Orders, select orders and use bulk action `چاپ آدرس سفارش‌ها (مستقل)` or `چاپ خلاصه سفارش‌ها (مستقل)`. On an individual order edit page, use the `چاپ آدرس` / `چاپ خلاصه سفارش` buttons in the order detail area. Labels print A6; order summaries print A4. Native browser printing also supports Save as PDF.

The new `admin-post.php` action requires an authenticated WooCommerce order manager plus a WordPress nonce; it never serves order data to anonymous visitors and sends no-store headers. The rollout takes a file-level backup under `/srv/backups/vesta-order-print-*` and automatically restores the old file if verification fails. There are no container restarts, WooCommerce order/database changes, site configuration changes, or changes to Cutella and app.vesta. CI confirmed PHP lint, WP/WooCommerce bootstrap and hook registration, synthetic (non-customer) address rendering, blocked anonymous access, origin store pages and the three public site homepages. An interactive logged-in bulk-print browser test with real orders has **not** been run. The original licence-dependent print button remains subject to the vendor error.



## Production resource safeguards (24 October 2026)

After the outage and VPS upgrade (5.8 GiB usable RAM), the following live protections were applied with a backup and origin smoke tests. See workflow `.github/workflows/apply-vesta-stability-20261024.yml`.

- Apache prefork Vesta: `MaxRequestWorkers 12`, Cutella: `6`. Both use `StartServers 2`, `MinSpareServers 2`, `MaxSpareServers 4`, and `MaxConnectionsPerChild 400`.
- Current containers: Vesta `docker update --memory 3040870400 --memory-swap 3670016000`; Cutella `--memory 1572864000 --memory-swap 1939865600`. These protect the host while leaving MariaDB uncapped for transactional safety.
- Apache configs persisted on host under `/srv/vestacutella/runtime/guards/`. `/usr/local/sbin/vesta-runtime-limits-enforcer` checks and restores settings every five minutes from `/etc/cron.d/vesta-runtime-limits`; source is `scripts/vesta-runtime-limits-enforcer-20261024.sh`.
- Future WordPress image builds include matching `mpm-prefork-guard.conf`. Docker Compose production memory settings and rotating json-file logs (20 MiB x 4 files) were validated and persisted without forcing container recreation; the rotation options take effect as containers are recreated.
- `/usr/local/sbin/vesta-resource-watchdog`, scheduled by `/etc/cron.d/vesta-resource-watchdog`, checks available memory (warn below 1 GiB), used swap (above 512 MiB), load (18+), disk (85%+), container states, and local storefront HTTP. Alerts use the existing administrative Telegram chat IDs configured in Vesta WordPress; log rotation for the monitor is under `/etc/logrotate.d/vesta-resource-watchdog`. Alerts have a 30-minute cooldown.
- External public availability is also monitored hourly through a conditional ChatGPT task, which notifies only on verified 5xx, timeouts or 523.
- App `vc-vestaapp-account` and `vc-vestaapp-market` were restarted after host upgrade. The app proxy required an Nginx reload due to a stale upstream Docker IP; the three hosts subsequently passed HTTP 200 checks.
- The live monitoring test delivered to all three configured admin Telegram recipients. Do not log or expose the stored Telegram bot token and chat IDs.
- WooCommerce order databases, WP uploads, order status, payment settings, cron jobs, and checkout sessions were not intentionally changed. Existing host WP-Cron remains separately locked and scheduled; do not arbitrarily disable or slow it.

To verify: rerun `.github/workflows/vesta-resource-baseline-20261024.yml`, inspect `/var/log/vesta-resource-watchdog.log` and `/var/log/vesta-runtime-limits-errors.log`, and smoke test storefront, cart, checkout, login and app. The live Apache rollback snapshot was created under `/srv/backups/vesta-stability-20261024T155737Z`. The future Compose persistence backup is under `/srv/backups/vesta-compose-logcaps-20261024T160718Z`. Never restore or modify DB volumes as part of memory tuning.
