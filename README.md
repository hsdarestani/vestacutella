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

Four Vesta homepage hero PNG files now have new WebP alternatives ending in .png.vc20261014.webp. The original PNGs remain unchanged, and the on-server must-use plugin vc-vesta-hero-webp.php uses an HTML picture/source element to deliver WebP with PNG fallback in eligible browsers. The guarded Deploy Vesta hero WebP safely workflow generates and validates these sidecar files and cleans only the homepage WP Rocket cache. It deliberately refuses to overwrite an existing deployment.

The Nginx config includes independent HTTPS and reverse-proxy routing for app.vesta-cosmetics.ir; do not replace it with an outdated version missing that route. Because it is single-file Docker bind mounted, the deployment workflow recreates only vc-nginx and verifies the host and container configuration checksums.

Vesta still runs PHP 7.4 with ionCube and older plugins; do not upgrade PHP directly in production without testing plugin compatibility in staging.

## CDN findings and open dependency

On 14 October 2026, the public Cutella domain was proxied by Cloudflare. Its HTML was DYNAMIC at the edge, intentionally keeping shopping sessions fresh; static images were cacheable. Public Vesta served through Nginx directly rather than a Cloudflare edge. There is no connected Cloudflare account or deployment credential in this repo, so zone-specific DNS or CDN Cache Rules must be changed only after appropriate account authorization, verifying mail MX and all subdomains.

## Verification

The Live capacity audit workflow checks the front page and shop images including srcset variants, login/cart/checkout/account GET responses, Cookie-based cache bypass, Redis separation and Nginx syntax. Public mobile Lighthouse performance captures external mobile page load measurements. These probes do not place purchases, send OTP messages or validate real payment callbacks.

All production edits must have backups, smoke tests and automated rollback. Avoid deleting WooCommerce orders, scheduled-action records, sessions or images in the name of speed.
