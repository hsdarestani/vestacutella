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

Vesta mobile Lighthouse still reports CLS around 0.88, from Woodmart Owl carousels; a visibility guard had no effect and was deliberately reverted. Static image and origin cache improvements do not imply Core Web Vitals pass. Do not remove interactive sliders or globally defer critical JS without a proven low-risk browser A/B win. Cutella still incurs render-blocking CSS; Revolution Slider and other WordPress frontend dependencies must be validated before removing assets.

Public Cutella uses Cloudflare, while Vesta remains directly on Nginx. Neither DNS nor Cloudflare zone Cache Rules were modified, because repository access does not establish authorization for the Cloudflare zone and unreviewed DNS changes can affect email, payment callbacks and the Vesta app.
