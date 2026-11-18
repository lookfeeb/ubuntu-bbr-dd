#!/bin/sh
# Loaded only by the patched Alpine trans.sh. No actions when sourced in tests.
# shellcheck shell=dash
# shellcheck disable=SC3043,SC2154
dd_fail() { echo "DD stopped: $*" >&2; exit 1; }

# This is a same-boot failure journal, never a token that skips verification.
# Keep it outside the sealed bundle and outside paths cleared by upstream.
dd_install_begin() {
    DD_INSTALL_STATE=${DD_INSTALL_STATE:-/run/ubuntu-dd-install}
    [ ! -L "$DD_INSTALL_STATE" ] || dd_fail 'Installation journal cannot be a symlink'
    mkdir -p "$DD_INSTALL_STATE"
    chmod 700 "$DD_INSTALL_STATE"
    mkdir "$DD_INSTALL_STATE/lock" 2>/dev/null || dd_fail 'Another or interrupted installer owns the journal; inspect it before retrying'
    # Inspect the boundary only after acquiring the lock: a preceding attempt
    # may have failed between our initial entry and the successful mkdir.
    if [ -e "$DD_INSTALL_STATE/destructive" ]; then
        rmdir "$DD_INSTALL_STATE/lock" 2>/dev/null || true
        dd_fail "A previous attempt started disk writes. Automatic restart is refused; inspect $DD_INSTALL_STATE and /reinstall.log from the installer console. Do not reboot an incomplete target."
    fi
    DD_INSTALL_ACTIVE=1
    DD_INSTALL_PHASE=preflight
    trap 'dd_install_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    rm -f "$DD_INSTALL_STATE/exit-status"
    dd_install_stage preflight
}

dd_install_stage() {
    DD_INSTALL_PHASE=$1
    [ "${DD_INSTALL_ACTIVE:-0}" = 1 ] || return 0
    # All values come from the installer, not credentials or user-data.
    (umask 077; printf 'phase=%s\ncache=%s\ndisk=%s\n' "$DD_INSTALL_PHASE" \
        "${DD_CACHE_MODE:-unknown}" "${xda:-unknown}" > "$DD_INSTALL_STATE/status.new")
    mv -f "$DD_INSTALL_STATE/status.new" "$DD_INSTALL_STATE/status"
    echo "DD stage: $DD_INSTALL_PHASE"
}

dd_install_exit() {
    local status=$1
    trap - EXIT INT TERM HUP
    # A successful pre-partition retry must replace the previous failure code.
    printf '%s\n' "$status" > "$DD_INSTALL_STATE/exit-status" || true
    if [ "$status" = 0 ]; then
        rmdir "$DD_INSTALL_STATE/lock" 2>/dev/null || true
        return 0
    fi
    echo "DD failed at stage ${DD_INSTALL_PHASE:-unknown}; automatic reboot was not reached." >&2
    if [ -e "$DD_INSTALL_STATE/destructive" ]; then
        echo 'Disk writes have started; the old system cannot be assumed recoverable. Keep the installer running and inspect /reinstall.log. Re-running trans.sh is blocked to prevent another erase.' >&2
    else
        echo 'Partitioning has not started; this attempt did not erase the original layout.' >&2
    fi
    # Persist only on the already-mounted cache; never mount or alter a disk
    # while handling an error, and never disturb its active swap.
    if dd_disk_cache && mountpoint -q /installer &&
       [ "$(readlink -f "$(findmnt -n -o SOURCE --target /installer)")" = "$(readlink -f "${dev_installer:-/nonexistent}")" ]; then
        (
            set +e
            mkdir -p /installer/dd-failure
            chmod 700 /installer/dd-failure
            cp "$DD_INSTALL_STATE/status" "$DD_INSTALL_STATE/exit-status" /installer/dd-failure/
            [ ! -f /reinstall.log ] || cp /reinstall.log /installer/dd-failure/reinstall.log
            sync
        ) || true
    fi
    # Retain ownership while writing evidence; a pre-partition retry must not
    # replace status while this attempt is still recording its failure.
    rmdir "$DD_INSTALL_STATE/lock" 2>/dev/null || true
    exit "$status"
}
dd_https() {
    command curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 20 --speed-limit 1024 --speed-time 120 "$@"
}

dd_download_image() {
    local url=$1 output=$2 bytes=$3 attempt=1 status size started
    started=$(date +%s)
    [ ! -L "$output" ] || dd_fail 'Image cache cannot be a symlink'
    while [ "$attempt" -le 4 ]; do
        size=0
        [ ! -f "$output" ] || size=$(stat -c %s "$output")
        [ "$size" -le "$bytes" ] || dd_fail 'Partial image exceeds authenticated size'
        if [ "$size" = "$bytes" ]; then break; fi
        # One retry budget. curl validates Content-Range before appending, and
        # the caller still verifies the exact size and signed SHA-256 in full.
        if dd_https --retry 0 --continue-at - --max-filesize "$bytes" --output "$output" "$url"; then
            break
        else status=$?; fi
        case "$status" in
            33|36) rm -f -- "$output" ;; # Server does not support resuming.
            5|6|7|18|22|28|35|52|55|56|92) ;; # Bounded retries for transport errors.
            *) dd_fail "Image download failed (curl $status)" ;;
        esac
        [ "$attempt" -lt 4 ] || dd_fail 'Image download retry limit reached'
        echo "Image transfer interrupted; retry $attempt/3, retaining partial data where supported."
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
    if [ ! -f "$output" ] || [ "$(stat -c %s "$output")" != "$bytes" ]; then dd_fail 'Incomplete image download'; fi
    echo "Image download completed: $bytes bytes, $(( $(date +%s) - started )) seconds; signature hash verification follows."
}

dd_wget() {
    # Narrow adapter for the Ubuntu path; unsupported options fail closed.
    local url='' output=- spider=0 headers=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            https://*) url=$1; shift ;;
            -O) output=$2; shift 2 ;;
            -O-) output=-; shift ;;
            --spider) spider=1; shift ;;
            -S) headers=1; shift ;;
            *) dd_fail "Unsupported wget argument: $1" ;;
        esac
    done
    [ -n "$url" ] || dd_fail 'HTTPS URL required'
    if [ "$spider" = 1 ]; then
        # Retain GNU wget's stderr header layout for upstream size parsing.
        dd_https --head "$url" | sed 's/^/  /' >&2
    elif [ "$headers" = 1 ]; then
        dd_https --dump-header /dev/stderr --output "$output" "$url"
    else
        dd_https --output "$output" "$url"
    fi
}

dd_verify_manifest() {
    local dir=$1 name=$2 expected
    mkdir -p "$dir/gnupg"
    chmod 700 "$dir/gnupg"
    gpgv --homedir "$dir/gnupg" --keyring "$DD_BUNDLE/ubuntu-cloudimage-keyring.gpg" \
        "$dir/SHA256SUMS.gpg" "$dir/SHA256SUMS" || dd_fail 'Ubuntu signature invalid'
    expected=$(awk -v n="$name" 'length($1)==64 && ($2==n || $2=="*"n) {print $1}' "$dir/SHA256SUMS")
    case "$expected" in ''|*[!a-f0-9]*) dd_fail 'Missing or ambiguous Ubuntu image hash' ;; esac
    [ "${#expected}" = 64 ] || dd_fail 'Duplicate Ubuntu image hash'
    printf '%s\n' "$expected"
}

dd_check_memory() {
    # Reserve 1 GiB working memory plus 1 GiB for APT cache/overlay.
    local bytes=$1 available=$2
    [ "$available" -ge "$((bytes + 2147483648))" ] || dd_fail 'Insufficient RAM for image, package cache and working reserve; original disk has not been erased'
}

dd_disk_cache() { [ "${DD_CACHE_MODE:-ram}" = disk ]; }

dd_check_minimum_ram() {
    [ "$1" -ge 469762048 ] || dd_fail 'At least nominal 512 MiB RAM (448 MiB MemTotal) is required'
}

dd_disk_cache_bytes() {
    local size=$(($1 + 4294967296))
    [ "$size" -ge 6442450944 ] || size=6442450944
    echo "$(( (size + 1048575) / 1048576 * 1048576 ))"
}

dd_require_partition() {
    # Recheck after downloads and immediately before the destructive boundary.
    dd_verify_disk_identity "/dev/$xda"
    if dd_disk_cache; then
        [ "${DD_PARTITION_READY:-0}" = 1 ] || dd_fail 'Disk partitioning not authorized by metadata preflight'
        # A process-local one-shot gate, never a persistent marker to bypass checks.
        DD_PARTITION_READY=0
    else
        dd_require_verified
    fi
    if [ "${DD_INSTALL_ACTIVE:-0}" = 1 ]; then
        [ ! -e "$DD_INSTALL_STATE/destructive" ] || dd_fail 'Repeated partitioning refused'
        # Record before the first destructive command, including partial failure.
        (umask 077; set -C; printf '%s\n' "${xda:-unknown}" > "$DD_INSTALL_STATE/destructive") || dd_fail 'Cannot record partition boundary'
        dd_install_stage partitioning
    fi
}

dd_prepare_install() {
    dd_preflight
    if ! dd_disk_cache; then create_part; fi
    download_qcow
}

dd_prepare_disk_cache() {
    local bytes=$1 total=$2 capacity reserve
    dd_check_minimum_ram "$total"
    capacity=$(blockdev --getsize64 "/dev/$xda")
    reserve=$(dd_disk_cache_bytes "$bytes")
    if [ "$capacity" -lt 17179869184 ] || [ "$capacity" -lt "$((reserve + 8589934592))" ]; then
        dd_fail 'Disk mode requires at least 16 GiB and 8 GiB outside the cache partition'
    fi
    # Authenticate the exact manifest and verify the HTTPS endpoint before
    # repartitioning. Full payload verification follows on the new disk cache.
    dd_verify_manifest "$DD_BUNDLE" "${img##*/}" >/dev/null || exit 1
    dd_https --head --output /dev/null "$img" || dd_fail 'Image endpoint unavailable; disk not erased'
    echo 'DISK CACHE: repartitioning now; later download or validation failures cannot restore the old system.'
    DD_PARTITION_READY=1
    create_part
    dd_install_stage cache-setup
    mkdir -p /installer
    mount "$dev_installer" /installer
    chmod 700 /installer
    # A real disk-backed swap file, never on tmpfs or the old erased layout.
    dd if=/dev/zero of=/installer/swapfile bs=1048576 count=2048 2>/dev/null || dd_fail 'Cannot allocate installer swap'
    chmod 600 /installer/swapfile
    mkswap /installer/swapfile
    swapon /installer/swapfile || dd_fail 'Cannot activate installer swap'
    DD_CACHE=/installer/dd-cache
    export DD_PACKAGE_SOURCE=$DD_CACHE/packages
    mkdir -p "$DD_CACHE"
    export DPKG_DEB_THREADS_MAX=1
}

dd_release_installer() {
    if dd_disk_cache; then sync; else umount /installer/; fi
}

dd_finish_partition_layout() {
    if dd_disk_cache; then
        echo 'Retaining installer partition for target swap and scratch space.'
    else
        parted "/dev/$xda" -s -- rm 3
        update_part
        resize_after_install_cloud_image
    fi
}

dd_finalize_disk_cache() {
    dd_disk_cache || return 0
    local root=$1 uuid source
    if [ "$DD_CACHE" != /installer/dd-cache ] || [ -L "$DD_CACHE" ]; then dd_fail 'Unexpected disk cache path'; fi
    source=$(findmnt -n -o SOURCE --target /installer)
    [ "$(readlink -f "$source")" = "$(readlink -f "$dev_installer")" ] || dd_fail 'Installer mount changed'
    if [ ! -f /installer/swapfile ] || [ -L /installer/swapfile ]; then dd_fail 'Installer swap missing'; fi
    grep -q '^/installer/swapfile ' /proc/swaps || dd_fail 'Installer swap is not active'
    uuid=$(blkid -s UUID -o value "$dev_installer")
    case "$uuid" in ''|*[!a-fA-F0-9-]*) dd_fail 'Invalid scratch filesystem UUID' ;; esac
    mkdir -p "$root/var/lib/ubuntu-dd/scratch"
    printf 'UUID=%s /var/lib/ubuntu-dd/scratch ext4 defaults,nosuid,nodev 0 2\n' "$uuid" >> "$root/etc/fstab"
    printf '/var/lib/ubuntu-dd/scratch/swapfile none swap sw 0 0\n' >> "$root/etc/fstab"
    printf 'cache=disk\nscratch_uuid=%s\nswap_bytes=2147483648\n' "$uuid" > "$root/var/lib/ubuntu-dd/storage-policy"
    # The NBD and package overlay must be detached before freeing this cache.
    if awk '$2 == "/installer/dd-cache" || index($2, "/installer/dd-cache/") == 1 {found=1} END {exit !found}' /proc/mounts; then
        dd_fail 'Nested cache mounts remain'
    fi
    rm -rf -- "$DD_CACHE"
    sync
}

dd_check_live_nics() {
    local mac driver path found actual
    while read -r mac driver; do
        [ -n "$mac" ] || continue
        found=0
        for path in /sys/class/net/*; do
            [ -e "$path/device" ] || continue
            [ "$(cat "$path/address")" = "$mac" ] || continue
            found=1
            actual=$(basename "$(readlink -f "$path/device/driver/module")")
            [ "$actual" = "$driver" ] || dd_fail "NIC $mac requires $driver, installer has $actual"
        done
        [ "$found" = 1 ] || dd_fail "NIC $mac not available in installer"
    done < "$DD_BUNDLE/nics"
    if ! ip -4 route show default | grep -q . && ! ip -6 route show default | grep -q .; then
        dd_fail 'Installer has no default route'
    fi
}

dd_check_kernel_drivers() {
    local root=$1 kernel=$2 driver filename
    while read -r driver; do
        [ -n "$driver" ] || continue
        filename=$(chroot "$root" modinfo -k "$kernel" -F filename "$driver") || dd_fail "Kernel $kernel missing $driver"
        [ -n "$filename" ] || dd_fail "Empty module result: $driver"
    done < "$DD_BUNDLE/drivers"
}

get_ubuntu_kernel_flavor() {
    case "$(cat "$DD_BUNDLE/cloud")" in
        gcp) echo gcp ;;
        aws|lightsail) echo aws ;;
        oci) echo oracle ;;
        *) dd_upstream_kernel_flavor ;;
    esac
}

dd_check_image_drivers() {
    local root=$1 kernel=$2 driver cloud
    cloud=$(cat "$DD_BUNDLE/cloud")
    while read -r driver; do
        if chroot "$root" modinfo -k "$kernel" "$driver" >/dev/null 2>&1; then continue; fi
        case "$cloud" in
            gcp|aws|lightsail|oci)
                # The generic cloud image does not ship every cloud driver
                # (notably gve). modify_ubuntu installs the selected cloud
                # kernel; dd_finalize_target then requires all its drivers.
                echo "Image kernel lacks $driver; selected cloud kernel must provide it before reboot." >&2 ;;
            *) dd_fail "Image kernel $kernel lacks $driver and no cloud kernel is selected" ;;
        esac
    done < "$DD_BUNDLE/drivers"
}

dd_preflight_image() (
    local part rootpart='' kernel
    modprobe nbd nbds_max=1 max_part=16
    [ ! -e /sys/block/nbd0/pid ] || dd_fail 'nbd0 is already in use'
    trap 'umount "$DD_CACHE/root" 2>/dev/null || true; qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true' EXIT
    qemu-nbd --read-only --format=qcow2 --connect=/dev/nbd0 "$DD_CACHE/image.img"
    local count=0
    while [ ! -b /dev/nbd0p1 ]; do
        count=$((count + 1)); [ "$count" -le 30 ] || dd_fail 'Image partition discovery timed out'
        sleep 1
    done
    mkdir -p "$DD_CACHE/root"
    for part in /dev/nbd0p*; do
        [ "$(blkid -s TYPE -o value "$part")" = ext4 ] || continue
        if mount -o ro,noload "$part" "$DD_CACHE/root"; then
            if [ -f "$DD_CACHE/root/etc/os-release" ]; then rootpart=$part; break; fi
            umount "$DD_CACHE/root"
        fi
    done
    [ -n "$rootpart" ] || dd_fail 'No Ubuntu root filesystem in signed image'
    grep -qx 'ID=ubuntu' "$DD_CACHE/root/etc/os-release" || dd_fail 'Image is not Ubuntu'
    grep -qx "VERSION_ID=\"$releasever\"" "$DD_CACHE/root/etc/os-release" || dd_fail 'Image version mismatch'
    local kernels=0
    for kernel in "$DD_CACHE/root"/lib/modules/*; do
        [ -d "$kernel" ] || continue
        dd_check_image_drivers "$DD_CACHE/root" "${kernel##*/}"
        kernels=$((kernels + 1))
    done
    [ "$kernels" -gt 0 ] || dd_fail 'Image contains no kernel modules'
    dd_cache_packages "$DD_CACHE/root"
    umount "$DD_CACHE/root"
    qemu-nbd --disconnect /dev/nbd0
    trap - EXIT
)

dd_preflight() {
    DD_IMAGE_VERIFIED=0
    DD_PARTITION_READY=0
    DD_CACHE_MODE=$(cat "$DD_BUNDLE/cache-mode")
    case "$DD_CACHE_MODE" in ram|disk) ;; *) dd_fail 'Invalid cache mode' ;; esac
    [ "$distro:$releasever:$img_type" = "ubuntu:24.04:qemu" ] ||
        [ "$distro:$releasever:$img_type" = "ubuntu:26.04:qemu" ] || dd_fail 'Unsupported installation path'
    [ "$img" = "$(cat "$DD_BUNDLE/image-url")" ] || dd_fail 'Image URL changed between stages'
    dd_verify_disk_identity "/dev/$xda"
    # Get all tools for verification and partitioning before allowing disk writes.
    apk add curl ca-certificates gnupg qemu-img jq util-linux parted e2fsprogs dosfstools
    dd_check_live_nics
    swapoff -a
    DD_CACHE=${DD_CACHE:-/dd-image-cache}
    mkdir -p "$DD_CACHE"
    if mountpoint -q "$DD_CACHE"; then umount "$DD_CACHE"; fi
    local bytes available digest virtual_size total
    bytes=$(cat "$DD_BUNDLE/image-bytes")
    available=$(awk '/MemAvailable:/ {printf "%.0f", $2*1024}' /proc/meminfo)
    total=$(awk '/MemTotal:/ {printf "%.0f", $2*1024}' /proc/meminfo)
    if dd_disk_cache; then
        dd_prepare_disk_cache "$bytes" "$total"
    else
        dd_check_memory "$bytes" "$available"
        mount -t tmpfs -o "size=$((bytes + 1073741824)),mode=0700,nosuid,nodev" tmpfs "$DD_CACHE"
    fi
    cp "$DD_BUNDLE/SHA256SUMS" "$DD_BUNDLE/SHA256SUMS.gpg" "$DD_CACHE/"
    digest=$(dd_verify_manifest "$DD_CACHE" "${img##*/}") || exit 1
    dd_install_stage image-download
    dd_download_image "$img" "$DD_CACHE/image.img.part" "$bytes"
    dd_install_stage image-validation
    [ "$(stat -c %s "$DD_CACHE/image.img.part")" = "$bytes" ] || dd_fail 'Image size changed; prepare installation again'
    printf '%s  %s\n' "$digest" "$DD_CACHE/image.img.part" | sha256sum -c - || dd_fail 'Ubuntu image checksum mismatch'
    mv "$DD_CACHE/image.img.part" "$DD_CACHE/image.img"
    qemu-img info --output=json "$DD_CACHE/image.img" > "$DD_CACHE/info.json"
    jq -e '.format == "qcow2" and (has("backing-filename") | not) and (has("data-file") | not) and ((.["format-specific"].data // {} | has("data-file")) | not)' "$DD_CACHE/info.json" >/dev/null || dd_fail 'Unsupported image format or external backing file'
    qemu-img check -f qcow2 "$DD_CACHE/image.img"
    virtual_size=$(jq -er '.["virtual-size"] | numbers' "$DD_CACHE/info.json")
    if dd_disk_cache; then
        [ "$(blockdev --getsize64 "$dev_os")" -ge "$((virtual_size + 1073741824))" ] || dd_fail 'Target root partition too small'
    fi
    [ "$(blockdev --getsize64 "/dev/$xda")" -ge "$((virtual_size + bytes + 268435456))" ] || dd_fail 'Disk too small for image and installer partition'
    dd_install_stage image-and-package-preflight
    dd_preflight_image
    dd_verify_package_cache "$DD_CACHE/packages"
    local package_bytes
    package_bytes=$(du -sk "$DD_CACHE/packages" | awk '{print $1 * 1024}')
    [ "$(blockdev --getsize64 "/dev/$xda")" -ge "$((virtual_size + bytes + package_bytes * 2 + 268435456))" ] || dd_fail 'Disk too small for image and package cache'
    # The gate is process-local; a retry must re-run all checks.
    DD_IMAGE_VERIFIED=1
    echo "Ubuntu signature, image, drivers and package verification passed (cache=$DD_CACHE_MODE)."
}

dd_require_verified() {
    if [ "${DD_IMAGE_VERIFIED:-0}" != 1 ] || [ ! -f "$DD_CACHE/image.img" ]; then
        dd_fail 'Disk write refused: image not verified'
    fi
    dd_verify_package_cache "$DD_CACHE/packages"
}

download_qcow() {
    dd_require_verified
    dd_install_stage image-copy
    if dd_disk_cache; then
        qcow_file=$DD_CACHE/image.img
        return
    fi
    mkdir -p /installer
    mount "/dev/$(xda installer)" /installer
    qcow_file=/installer/cloud_image.qcow2
    cp "$DD_CACHE/image.img" "$qcow_file"
    cmp "$DD_CACHE/image.img" "$qcow_file" || dd_fail 'Installer disk copy differs from verified image'
    cp -a "$DD_CACHE/packages" /installer/dd-packages
    dd_verify_package_cache /installer/dd-packages
    umount "$DD_CACHE"
}

get_cloud_image_part_size() {
    if dd_disk_cache; then
        echo "$(($(dd_disk_cache_bytes "$(cat "$DD_BUNDLE/image-bytes")") / 1048576))MiB"
        return
    fi
    local package_bytes
    package_bytes=$(du -sk "$DD_CACHE/packages" | awk '{print $1 * 1024}')
    echo "$(get_part_size_mb_for_file_size_b "$(($(cat "$DD_BUNDLE/image-bytes") + package_bytes))")MiB"
}

dd_cloud_init_policy() {
    local root=$1 cloud datasource
    cloud=$(cat "$DD_BUNDLE/cloud")
    case "$cloud" in gcp) datasource=GCE ;; aws|lightsail) datasource=Ec2 ;; oci) datasource=Oracle ;; *) datasource=None ;; esac
    # Let cloud-init identify the instance, but keep installer-owned network and
    # credentials. Do not execute metadata user-data, vendor scripts or agents.
    mkdir -p "$root/etc/cloud/cloud.cfg.d"
    cat > "$root/etc/cloud/cloud.cfg.d/99-zz-ubuntu-dd.cfg" <<EOF
datasource_list: [ $datasource, None ]
network: {config: disabled}
disable_root: false
users: []
allow_userdata: false
cloud_init_modules: [seed_random]
cloud_config_modules: []
cloud_final_modules: []
EOF
    # GCE probes metadata during init-local, before the DNS resolver is ready.
    # The link-local endpoint is reachable using the temporary DHCP route.
    if [ "$cloud" = gcp ]; then
        cat >> "$root/etc/cloud/cloud.cfg.d/99-zz-ubuntu-dd.cfg" <<'EOF'
datasource:
  GCE:
    metadata_url: http://169.254.169.254/computeMetadata/v1/
EOF
    fi
    rm -f "$root/etc/cloud/cloud-init.disabled"
    mkdir -p "$root/var/lib/ubuntu-dd"
    printf 'cloud=%s\nnetwork=installer\ncredentials=installer\nmetadata_scripts=disabled\n' "$cloud" > "$root/var/lib/ubuntu-dd/cloud-policy"
}

dd_finalize_target() {
    local root=$1 kernel driver filename modules count=0
    dd_cloud_init_policy "$root"
    # Required drivers include detected NICs and active storage bus modules.
    mkdir -p "$root/etc/initramfs-tools"
    touch "$root/etc/initramfs-tools/modules"
    while read -r driver; do
        grep -qxF "$driver" "$root/etc/initramfs-tools/modules" || echo "$driver" >> "$root/etc/initramfs-tools/modules"
    done < "$DD_BUNDLE/drivers"
    # Require a real initramfs boot, including on cloud images using PARTUUID.
    if [ -f "$root/etc/default/grub.d/40-force-partuuid.cfg" ]; then
        sed -i '/^GRUB_FORCE_PARTUUID=/d' "$root/etc/default/grub.d/40-force-partuuid.cfg"
    fi
    chroot "$root" update-initramfs -u -k all
    chroot "$root" update-grub
    for kernel in "$root"/boot/vmlinuz-*; do
        [ -f "$kernel" ] || continue
        kernel=${kernel##*/vmlinuz-}
        count=$((count + 1))
        dd_check_kernel_drivers "$root" "$kernel"
        [ -s "$root/boot/initrd.img-$kernel" ] || dd_fail "Missing initramfs for $kernel"
        modules=$(chroot "$root" lsinitramfs "/boot/initrd.img-$kernel") || dd_fail 'Cannot inspect initramfs'
        while read -r driver; do
            filename=$(chroot "$root" modinfo -k "$kernel" -F filename "$driver")
            [ "$filename" = '(builtin)' ] && continue
            filename=${filename##*/}
            echo "$modules" | grep -qF "/$filename" || dd_fail "initramfs missing $driver"
        done < "$DD_BUNDLE/drivers"
    done
    if [ "$count" -eq 0 ] || [ ! -s "$root/boot/grub/grub.cfg" ]; then dd_fail 'Missing target boot files'; fi
    if [ -d /sys/firmware/efi ]; then
        find "$root/boot/efi/EFI" -type f -iname '*.efi' | grep -q . || dd_fail 'Missing target EFI loader'
    fi
    chroot "$root" netplan generate
    chroot "$root" ssh-keygen -A
    mkdir -p "$root/run/sshd"
    chroot "$root" /usr/sbin/sshd -t
    local sshconfig
    sshconfig=$(chroot "$root" /usr/sbin/sshd -T)
    echo "$sshconfig" | grep -qx "port $ssh_port" || dd_fail 'SSH port mismatch'
    if [ -s /configs/ssh_keys ]; then
        echo "$sshconfig" | grep -qx 'pubkeyauthentication yes' || dd_fail 'SSH public key authentication disabled'
        [ -s "$root/root/.ssh/authorized_keys" ] || dd_fail 'Root authorized_keys missing'
        echo "$sshconfig" | grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$' || dd_fail 'Root key login disabled'
    else
        echo "$sshconfig" | grep -qx 'passwordauthentication yes' || dd_fail 'SSH password authentication disabled'
        echo "$sshconfig" | grep -qx 'permitrootlogin yes' || dd_fail 'Root password login disabled'
        local root_hash
        root_hash=$(awk -F: '$1 == "root" {print $2}' "$root/etc/shadow")
        case "$root_hash" in ''|\!*|\**) dd_fail 'Root password is empty or locked' ;; esac
    fi
    cp "$DD_BUNDLE/nics" "$DD_BUNDLE/drivers" "$root/var/lib/ubuntu-dd/"
    dd_finalize_disk_cache "$root"
    echo 'Target kernel, initramfs, netplan and SSH checks passed.'
}
