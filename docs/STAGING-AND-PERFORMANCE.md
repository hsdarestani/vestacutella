# Vesta & Cutella — zero-disruption staging and performance

## Verified capacity (14 October 2026)

Production host: 3.9 GiB RAM (1.58 GiB available at inspection), 509 MiB swap in use, 22 GiB disk available. Production also hosts Vesta app services, two Apache/PHP WordPress containers, two MariaDB instances, Nginx and Redis. **Do not run a second full WordPress+MariaDB pair on this production host:** resources and data-isolation risks are unacceptable.

## Staging currently available

A separate, temporary GitHub-hosted Chromium runner runs real mobile website performance and regression experiments without modifying the stores:

- `.github/workflows/perf-ab-experiments.yml`: compare CSS candidate with several cold-browser baselines, verify selectors actually match elements, track mobile FCP, LCP, CLS, long tasks and layout/scroll behavior.
- `.github/workflows/cutella-mobile-asset-lab.yml`: emulate slow mobile CPU and network, selectively block test resources only in browser and verify banners, product cards and JS errors.
- `.github/workflows/storefront-browser-smoke.yml`: real-browser smoke tests for home, shop, sample product, login, cart, account, checkout empty-cart redirection and Vesta app.
- `.github/workflows/public-mobile-lighthouse.yml`: external mobile Lighthouse measurements and JSON artifacts.

This is **browser and presentation staging**, not a full transactional copy of WordPress. It cannot prove server-side plugin interactions, SMS OTP, real order payment callbacks or account-specific behavior.

## Full WooCommerce staging: prerequisites and isolation

To support transactional UAT without affecting customers, provision **a separate VPS** with at least 4 GiB RAM and adequate disk space (40+ GiB recommended, depending on media and sanitized database sizes). Do not reuse production SSH credentials, database passwords, payment gateway keys or application secrets. Create an independent staging Docker network, MariaDB databases, WordPress containers and isolated Redis prefixes. Configure the staging domains behind restricted access and `noindex`; never publish customer/private records.

Data handling: copy only a **sanitized subset** of product/catalog and public content. Strip all original customer email addresses, names, phone numbers, street addresses, API keys, order references and payment metadata. Do not connect live payments, shipping gateways, SMS or transactional email: use sandbox/mock endpoints. Block outgoing traffic to production integrations until test mocks are configured. Keep staging's database and runtime secrets solely on the staging host; never upload SQL dumps or private WordPress files to GitHub Actions artifacts.

Before promoting a change, test add-to-cart, quantity change, coupon, product variants, login/OTP sandbox, checkout mock callback, image loading, mobile scroll/click, Vesta app sync mocks and rollback. Stage one candidate at a time. On production only promote verified, reversible changes with a last-known-good backup and smoke tests.

## Current site safeguards

Vesta's existing browser-validated pre-init Owl Carousel CSS is a separate must-use plugin, with a rollback script and an observed CLS improvement from ~0.85 to ~0.38 (browser lab), measured around 0.236 in one Lighthouse run. Both stores use isolated Redis database/prefixes; Cutella guest-only microcache never caches cookies or authenticated/cart/checkout routes. Nine Vesta WebP sidecars leave originals untouched. Do not re-run legacy migration scripts on populated services.

**Pending external capability:** Vesta's Cloudflare/DNS records and associated mail, app, payment callback, and registrar settings require authorized Cloudflare/registrar access and a verified complete DNS inventory before switching nameservers or proxy modes. No CDN DNS changes should be made as part of an unverified speed tweak.
