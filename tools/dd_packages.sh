#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC3043,SC2154,SC2086,SC2046
# Preflight uses a cache-backed overlay on the authenticated read-only image.
# APT downloads and authenticates packages without running maintainer scripts.
dd_package_plan() {
    printf '%s\n' "linux-image-$(get_ubuntu_kernel_flavor)" openssh-server netplan.io initramfs-tools
    if is_efi; then
        case "$(uname -m)" in
            x86_64) echo grub-efi-amd64-signed; echo shim-signed ;;
            aarch64) echo grub-efi-arm64-signed; echo shim-signed ;;
        esac
    else
        echo grub-pc
    fi
    get_ucode_firmware_pkgs
}

dd_verify_package_cache() {
    local cache=$1
    if [ ! -s "$cache/SHA256SUMS" ] || [ ! -s "$cache/plan" ]; then dd_fail 'Package cache is incomplete'; fi
    (cd "$cache" && sha256sum -c SHA256SUMS >/dev/null) || dd_fail 'Package cache checksum failed'
}

dd_cache_packages() (
    local image_root=$1 stage="$DD_CACHE/package-stage" work="$DD_CACHE/package-work" file pkg kernel count=0
    DD_PACKAGE_CACHE="$DD_CACHE/packages"
    mkdir -p "$stage" "$work/upper" "$work/work" "$DD_PACKAGE_CACHE"
    grep -qw overlay /proc/filesystems || modprobe overlay
    mount -t overlay overlay -o "lowerdir=$image_root,upperdir=$work/upper,workdir=$work/work" "$stage"
    trap 'umount "$stage/dev" 2>/dev/null || true; umount "$stage/proc" 2>/dev/null || true; umount "$stage" 2>/dev/null || true' EXIT
    mount --bind /dev "$stage/dev"
    mount -t proc proc "$stage/proc"
    # Unlink the image symlink before copying, so an absolute target cannot
    # resolve outside this overlay while preparing DNS.
    rm -f "$stage/etc/resolv.conf"
    cp /etc/resolv.conf "$stage/etc/resolv.conf"
    dd_package_plan > "$DD_PACKAGE_CACHE/plan.unsorted"
    sort -u "$DD_PACKAGE_CACHE/plan.unsorted" > "$DD_PACKAGE_CACHE/plan"
    rm "$DD_PACKAGE_CACHE/plan.unsorted"
    [ -s "$DD_PACKAGE_CACHE/plan" ] || dd_fail 'Empty APT prefetch plan'
    chroot "$stage" apt-get -o APT::Update::Error-Mode=any -o Acquire::Languages=none \
        -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update
    # Already installed current packages are present in the signed image; the
    # final offline transaction does not reinstall them either.
    DEBIAN_FRONTEND=noninteractive chroot "$stage" apt-get --download-only -y \
        -o Acquire::Languages=none -o Acquire::Retries=3 \
        -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install $(cat "$DD_PACKAGE_CACHE/plan")
    mkdir -p "$DD_PACKAGE_CACHE/archives" "$DD_PACKAGE_CACHE/lists"
    for file in "$stage"/var/cache/apt/archives/*.deb; do
        [ -f "$file" ] || continue
        pkg=$(chroot "$stage" dpkg-deb -f "/var/cache/apt/archives/${file##*/}" Package)
        case "$pkg" in
            linux-image-[0-9]*|linux-modules-*)
                # Extract only to the disposable overlay. No maintainer scripts.
                chroot "$stage" dpkg-deb -x "/var/cache/apt/archives/${file##*/}" / ;;
        esac
        mv "$file" "$DD_PACKAGE_CACHE/archives/"
    done
    cp -a "$stage/var/lib/apt/lists/." "$DD_PACKAGE_CACHE/lists/"
    # The stock generic image may lack GVE. Now inspect the selected cloud
    # kernel from authenticated .debs, before the target disk is modified.
    local flavor
    flavor=$(get_ubuntu_kernel_flavor)
    case "$flavor" in gcp|aws|oracle|azure|ibm|vmware) ;; *) flavor=generic ;; esac
    for kernel in "$stage"/lib/modules/*-"$flavor"; do
        [ -d "$kernel" ] || continue
        chroot "$stage" depmod -a "${kernel##*/}"
        dd_check_kernel_drivers "$stage" "${kernel##*/}"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || dd_fail 'Selected kernel has no module tree in cache/image'
    (cd "$DD_PACKAGE_CACHE" && find plan archives lists -type f -exec sha256sum {} \; > SHA256SUMS)
    dd_verify_package_cache "$DD_PACKAGE_CACHE"
    umount "$stage/dev"
    umount "$stage/proc"
    umount "$stage"
    trap - EXIT
    # Paths are fixed children of this newly created cache, with all
    # nested mounts removed. Free extracted modules and temporary APT data.
    rm -rf -- "$work"
)

dd_seed_packages() {
    local root=$1 cache=${DD_PACKAGE_SOURCE:-/installer/dd-packages}
    dd_verify_package_cache "$cache"
    mkdir -p "$root/var/cache/apt/archives" "$root/var/lib/apt/lists" "$root/var/lib/ubuntu-dd"
    cp -a "$cache/archives/." "$root/var/cache/apt/archives/"
    cp -a "$cache/lists/." "$root/var/lib/apt/lists/"
    cp "$cache/plan" "$root/var/lib/ubuntu-dd/package-plan"
    cp "$cache/SHA256SUMS" "$root/var/lib/ubuntu-dd/package-cache.sha256"
    touch "$root/var/lib/ubuntu-dd/packages-ready"
    # Preserve already installed planned dependencies through the upstream
    # cleanup. The selected new cloud kernel is marked manual on installation.
    local pkg
    while read -r pkg; do
        if chroot "$root" dpkg -s "$pkg" >/dev/null 2>&1; then chroot "$root" apt-mark manual "$pkg"; fi
    done < "$cache/plan"
}

dd_apt_update() {
    [ -f "$1/var/lib/ubuntu-dd/packages-ready" ] || dd_fail 'Offline APT cache was not seeded'
    # The authenticated indexes were copied from preflight. Never refresh
    # them after erasing the disk, which could select uncached package versions.
}

dd_install_packages() {
    local root=$1
    dd_apt_update "$root"
    if dd_disk_cache; then
        mkdir -p "$root/etc/initramfs-tools/conf.d"
        printf 'COMPRESS=gzip\n' > "$root/etc/initramfs-tools/conf.d/zz-dd-lowmem"
        export DPKG_DEB_THREADS_MAX=1
    fi
    # Request every planned package against the same indexes. Already current
    # packages stay installed, avoiding needless SSH/bootloader postinst runs.
    # --no-download refuses any unanticipated dependency.
    DEBIAN_FRONTEND=noninteractive chroot "$root" apt-get --no-download -y install $(cat "$root/var/lib/ubuntu-dd/package-plan")
}
