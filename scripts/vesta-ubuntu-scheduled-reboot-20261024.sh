#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
echo "== OS UPDATE REBOOT READINESS =="
test -s /srv/backups/ubuntu-maintenance-20261024/status
grep -q 'UPGRADE_APT_SUCCESS' /srv/backups/ubuntu-maintenance-20261024/status
test -z "$(dpkg --audit)"
expected=$(basename "$(readlink -f /boot/vmlinuz)" | sed 's/^vmlinuz-//')
echo "running=$(uname -r) installed_default=$expected"
test -n "$expected"
test -e "/boot/vmlinuz-$expected"
test -e "/boot/initrd.img-$expected"
if [ "$(uname -r)" = "$expected" ];then echo "ALREADY_RUNNING_EXPECTED_KERNEL";exit 0;fi
if [ -f /run/reboot-required ];then echo "reboot_required=yes";else echo "reboot_required=kernel_transition";fi
echo "== BACKUPS AND DISK =="
test -s /srv/backups/vesta-full-db-verify-20261024/vestacos_m-full.sql.gz
test -s /srv/backups/vesta-action-scheduler-pre-repair-20261024/cutella-database.sql.gz
df -h /
echo "SCHEDULING_REBOOT_IN_20_SECONDS"
systemd-run --unit=vesta-ubuntu-update-reboot --on-active=20s /usr/bin/systemctl reboot
echo "REBOOT_SCHEDULED"
