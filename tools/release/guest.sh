#!/usr/bin/env bash
# This file is copied into a disposable QEMU guest; never run on the host.
set -Eeuo pipefail
[[ $(hostname) == guard-release-lab && -f /root/guard-release/guest-marker ]]
[[ $(systemd-detect-virt) == qemu || $(systemd-detect-virt) == kvm ]]
cd /root/guard-release
phase=${1:?Missing guest test phase}
# shellcheck source=/dev/null
source ./bbr.sh
export DEBIAN_FRONTEND=noninteractive
case "$phase" in
    setup)
        uname -r > original-kernel
        apt-get update
        apt-get install -y --no-remove --no-install-recommends build-essential gcc-x86-64-linux-gnu \
            python3 curl ca-certificates kmod initramfs-tools zstd ethtool
        systemctl is-active ssh
        curl -fsS --retry 3 --max-time 60 -o /dev/null https://example.com
        ;;
    install)
        sha256sum -c packages.sha256
        require_host; select_profile
        (cd packages; sha256sum linux-*.deb > SHA256SUMS)
        export BBR_PACKAGE_DIR=$PWD/packages
        install_prebuilt_kernel
        systemctl disable --now bbr-kernel-cleanup.timer
        test -e "$STATE/cleanup-pending"
        test "$(cat "$STATE/rollback-release")" = "$(cat original-kernel)"
        verify_rollback_kernel "$(cat original-kernel)"
        ;;
    new|return|clean)
        test "$(uname -r)" = "$PREBUILT_RELEASE"
        test "$(modinfo -F version tcp_bbr_guard)" = 3-guard7-r2-experimental
        test "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbrguard
        systemctl is-active ssh
        curl -fsS --retry 3 --max-time 60 -o /dev/null https://example.com
        sha256sum -c packages.sha256
        if [[ $phase == new ]]; then
            mkdir headers-check
            cat > headers-check/guard_headers_check.c <<'C'
#include <linux/init.h>
#include <linux/module.h>
static int __init check_init(void) { return 0; }
static void __exit check_exit(void) { }
module_init(check_init);
module_exit(check_exit);
MODULE_LICENSE("GPL");
C
            printf '%s\n' 'obj-m += guard_headers_check.o' > headers-check/Makefile
            make -C "/lib/modules/$(uname -r)/build" M="$PWD/headers-check" -j2 modules
            test "$(modinfo -F vermagic headers-check/guard_headers_check.ko | cut -d ' ' -f 1)" = "$PREBUILT_RELEASE"
            insmod headers-check/guard_headers_check.ko
            test -d /sys/module/guard_headers_check
            rmmod guard_headers_check
            test ! -d /sys/module/guard_headers_check
        else
            require_host
            cleanup_old_kernels
            test ! -e "$STATE/cleanup-pending"
            test ! -e "$STATE/cleanup-incomplete"
            test ! -e "$STATE/rollback-release"
            verify_running_kernel_files "$PREBUILT_RELEASE"
            verify_only_current_kernel "$PREBUILT_RELEASE"
            test ! -e "/boot/vmlinuz-$(cat original-kernel)"
            test ! -d "/lib/modules/$(cat original-kernel)"
        fi
        ;;
    rollback)
        test "$(uname -r)" = "$PREBUILT_RELEASE"
        require_host
        restore_bbr
        old_entry=$(grub_entry_for "$(cat original-kernel)")
        grub-reboot "$old_entry"
        grub-editenv list | grep -Fx "next_entry=$old_entry"
        ;;
    old)
        test "$(uname -r)" = "$(cat original-kernel)"
        systemctl is-active ssh
        curl -fsS --retry 3 --max-time 60 -o /dev/null https://example.com
        require_host; select_profile; write_bbr_config
        ;;
    *) exit 2 ;;
esac
printf 'GUARD_RELEASE_PHASE_PASS=%s\n' "$phase"
