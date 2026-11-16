# Vesta backup before Mahak image synchronization changes

Owner requested a current backup to protect existing product photographs before third-party changes. No image sync settings, product data or installer access were changed by this operation.

- Started: 2026-11-16 08:52:08 UTC (12:22:08 Tehran).
- Verified: 2026-11-16 09:01:30 UTC (12:31:30 Tehran).
- Private server location: `/srv/backups/vesta-before-mahak-images-20261116T085208Z`.
- WordPress archive: 7.9 GiB, 139,095 entries, including 66,000 upload entries (files and directories; not a count of unique product photos).
- Transaction-consistent MariaDB export: 138 MiB compressed.
- Separate attachment/product image relationship export: 1.6 MiB compressed.
- Full gzip/tar listing and SHA256 checks passed for the generated archives.
- All three domains returned HTTP 200 afterward.
- Execution: https://github.com/hsdarestani/vestacutella/actions/runs/43834703897
- Post-backup warning inspection: https://github.com/hsdarestani/vestacutella/actions/runs/43836173127

## Limits and recovery

This was an online backup. Tar recorded directory changes in uploads, the product page cache, and wp-content; no individual-file read/change warnings were reported. Changes created after directory enumeration may not be included. Active vc-debug.log was deliberately excluded. The filesystem archive is not an atomic snapshot coordinated with the database.

No restore rehearsal or independent off-server copy was performed. Checksums and readable archives establish archive integrity, not a completed restoration test. Keep the backup private: it contains database/customer data and wp-config.

For accidental image loss, first restore into an isolated environment and recover selected uploads, attachment records and product image relationships. Preserve orders and financial acknowledgements created after the backup; do not blindly roll the whole live database back.

For a later image-sync change, require that an absent or empty Mahak image preserves existing WooCommerce featured images and galleries, then validate a small sample before a bulk sync. This safeguard has not been implemented as part of the backup request.
