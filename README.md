# VestaCutella infrastructure

Infrastructure and migration tooling for Cutella and Vesta.

## Goal

- Keep the current WooCommerce sites running unchanged during migration.
- Move production WordPress from DirectAdmin hosting to Hetzner.
- Keep application configuration portable so the stack can later be restored on an Iran-based VPS.
- Develop future non-WordPress replacements separately on subdomains.
- Never commit backups, database dumps, WordPress uploads, credentials, or `.env` files.

## Server paths

- `/srv/migration` — uploaded DirectAdmin backup
- `/srv/vestacutella` — production infrastructure
- `/srv/backups` — portable backups

The current DirectAdmin archive is expected at `/srv/migration/backup-Oct-07-2026-2.tar.gz`.
