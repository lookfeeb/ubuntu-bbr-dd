#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
TOOL_VERSION=3.3.13
DRY_RUN=0
ACTION=menu
CLOUD=auto
SYS_ROOT=/sys
NIC_NAMES=()
NIC_DRIVERS=()
HAS_GVNIC=0
STATE=/var/lib/bbr-kernel
SYSCTL_FILE=/etc/sysctl.d/99-zz-bbr-kernel.conf
MODULES_FILE=/etc/modules-load.d/bbr-kernel.conf
BBR_COMMIT=674859761ded9f32690c7bdaf22ef585531452ed
KERNEL_VERSION=7.3.5
KERNEL_SHA256=8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990
JOBS=
PROFILE=recovery
ALGORITHM=bbrguard
BBR_MODULE=tcp_bbr_guard
PREBUILT_TAG=v$TOOL_VERSION
PREBUILT_RELEASE=7.3.5-bbrguard7r2only-674859761ded
PREBUILT_VERSION=7.3.5-guard7r2.1
PREBUILT_ARCH=amd64
PREBUILT_IMAGE_SHA256=
PREBUILT_HEADERS_SHA256=

# BEGIN HOST HELPERS
say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1，请先安装对应的软件包。"; }

read_os() {
    [[ -r /etc/os-release ]] || die '无法识别 Linux 发行版。'
    # shellcheck source=/dev/null
    . /etc/os-release
}

require_host() {
    [[ $(uname -s) == Linux ]] || die '请在目标 Linux VPS 上运行。'
    (( EUID == 0 )) || die '请使用 sudo 或 root 运行。'
    [[ ! -e /.dockerenv && ! -e /run/.containerenv ]] || die '容器共享宿主机内核，不能在此安装内核或 DD。'
    [[ ! -d /proc/vz || -d /proc/bc ]] || die '不支持 OpenVZ 容器。'
    if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease; then
        die 'WSL 仅用于预览和测试，不能安装 VPS 内核或 DD。'
    fi
    if command -v systemd-detect-virt >/dev/null && systemd-detect-virt --container --quiet; then
        die '不支持容器环境。'
    fi
    read_os
    case "$ID" in ubuntu|debian) ;; *) die '当前系统仅支持 Debian / Ubuntu。' ;; esac
    need flock
    install -d -m 700 "$STATE"
    install -d -m 700 /var/lib/vps-maintenance
    exec 9>/var/lib/vps-maintenance/operation.lock
    flock -n 9 || die '另一个操作正在执行。'
}

secure_boot_check() {
    [[ -d /sys/firmware/efi ]] || return 0
    local -a vars=(/sys/firmware/efi/efivars/SecureBoot-*)
    [[ -r ${vars[0]} ]] || die '无法读取 Secure Boot 状态；请先在控制台确认并关闭 Secure Boot。'
    local value
    value=$(od -An -t u1 -j 4 -N 1 "${vars[0]}" | tr -d '[:space:]')
    [[ $value == 0 ]] || die 'Secure Boot 已开启或状态未知，请关闭后再安装内核或重装系统。'
}

download_verified() {
    local url=$1 output=$2 expected=$3 resume=${4:-0} actual tmp attempt status http_code
    need curl; need sha256sum
    [[ $expected =~ ^[a-f0-9]{64}$ ]] || die '下载散列格式异常。'
    [[ $resume == 0 || $resume == 1 ]] || die '下载续传参数异常。'
    [[ ! -L $output && ( ! -e $output || -f $output ) ]] || die "下载目标路径异常：$output。"
    if [[ -f $output ]]; then
        actual=$(sha256sum "$output"); actual=${actual%% *}
        [[ $actual == "$expected" ]] && return 0
        die "缓存校验失败：$output。请移走该文件后重试。"
    fi
    if (( resume )); then
        tmp=$output.part.$expected
        [[ ! -L $tmp && ( ! -e $tmp || -f $tmp ) ]] || die '下载缓存路径异常，未覆盖。'
        for attempt in 1 2 3 4; do
            # A prior process may have finished downloading before it could rename.
            if [[ -f $tmp ]]; then
                actual=$(sha256sum "$tmp"); actual=${actual%% *}
                [[ $actual != "$expected" ]] || break
            fi
            if http_code=$(curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
                --retry 0 --connect-timeout 20 --speed-limit 1024 --speed-time 120 \
                --continue-at - --write-out '%{http_code}' --output "$tmp" "$url"); then
                # curl can treat HTTP 416 as an already completed transfer. The
                # cached hash above did not match, so restart this partial file.
                [[ $http_code == 416 ]] || break
                status=22
            else status=$?; fi
            case "$status" in
                33|36) rm -f -- "$tmp" ;; # Range unsupported: retry from zero.
                22) [[ $http_code != 416 ]] || rm -f -- "$tmp" ;; # Invalid partial offset.
                5|6|7|18|28|35|52|55|56|92) ;; # Preserve partial transport data.
                *) die "下载失败（curl $status），保留缓存供重试：$tmp。" ;;
            esac
            (( attempt < 4 )) || die "下载重试已达上限，保留缓存：$tmp。"
            sleep "$attempt"
        done
    else
        tmp=$(mktemp "${output}.part.XXXXXX")
        if ! curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --retry 3 --connect-timeout 20 --speed-limit 1024 --speed-time 120 --output "$tmp" "$url"; then
            rm -f -- "$tmp"; die '下载失败，未执行下载内容。'
        fi
    fi
    actual=$(sha256sum "$tmp"); actual=${actual%% *}
    if [[ $actual != "$expected" ]]; then rm -f -- "$tmp"; die 'SHA-256 校验失败，未执行下载内容。'; fi
    mv -T -- "$tmp" "$output" || { rm -f -- "$tmp"; die '保存下载文件失败。'; }
}
# END HOST HELPERS

# BEGIN RELEASE HELPERS
# Resolve one published project release, then verify and run its matching asset.
# Dependency versions inside that release remain unchanged.
release_checksum() {
    local manifest=$1 name=$2
    awk -v name="$name" '
        $2 == name || $2 == "*" name {
            count++
            if (NF == 2 && length($1) == 64 && $1 !~ /[^0-9a-f]/) digest=$1
        }
        END { if (count != 1 || digest == "") exit 1; print digest }
    ' "$manifest"
}

run_latest_release() {
    local name=$1 current=$2 actual
    case "$name" in bbr.sh|dd.sh) ;; *) die '未知发布脚本。' ;; esac
    case "${BBR_DD_AUTO_UPDATE:-1}" in
        0) return 0 ;;
        1) ;;
        *) die 'BBR_DD_AUTO_UPDATE 仅支持 0 或 1。' ;;
    esac
    need sha256sum
    # Only the verified child may skip a second check in this invocation.
    if [[ ${BBR_DD_RELEASE_SHA256:-} =~ ^[a-f0-9]{64}$ ]]; then
        actual=$(sha256sum -- "$current") || die '无法校验当前脚本。'
        actual=${actual%% *}
        if [[ $actual == "$BBR_DD_RELEASE_SHA256" ]]; then
            unset BBR_DD_RELEASE_SHA256
            return 0
        fi
    fi
    unset BBR_DD_RELEASE_SHA256
    need curl; need awk; need mktemp
    say '正在检查本项目最新 Release…'
    (
        # Keep the downloaded file until its menu and any installer preparation
        # finish. In particular, the BBR health service copies the running file.
        work=$(mktemp -d "${TMPDIR:-/tmp}/bbr-dd-release.XXXXXX") || exit 1
        trap 'rm -rf -- "$work"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        base=https://github.com/lookfeeb/ubuntu-bbr-dd
        if ! location=$(curl --fail --silent --show-error --location --head \
            --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 \
            --connect-timeout 10 --max-time 30 --retry 1 \
            --output /dev/null --write-out '%{url_effective}' "$base/releases/latest"); then
            die '无法获取最新 Release；本次已停止。离线使用本地版可设置 BBR_DD_AUTO_UPDATE=0。'
        fi
        [[ $location =~ ^https://github\.com/lookfeeb/ubuntu-bbr-dd/releases/tag/(v[0-9]+\.[0-9]+\.[0-9]+)$ ]] ||
            die '最新 Release 地址或版本格式异常。'
        tag=${BASH_REMATCH[1]}
        url=$base/releases/download/$tag
        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 \
            --connect-timeout 10 --max-time 60 --retry 1 --max-filesize 1048576 \
            --output "$work/SHA256SUMS" "$url/SHA256SUMS" || die '下载发布校验清单失败。'
        expected=$(release_checksum "$work/SHA256SUMS" "$name") || die '发布清单缺少唯一有效的脚本 SHA-256。'
        actual=$(sha256sum -- "$current") || die '无法读取当前脚本。'
        actual=${actual%% *}
        if [[ $actual == "$expected" ]]; then
            cp -- "$current" "$work/$name" || die '无法准备已校验脚本。'
        else
            say "正在获取最新发布版 $tag 的 $name…"
            curl --fail --silent --show-error --location \
                --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 \
                --connect-timeout 10 --max-time 120 --retry 1 --max-filesize 4194304 \
                --output "$work/$name" "$url/$name" || die '下载最新版脚本失败。'
        fi
        actual=$(sha256sum -- "$work/$name") || die '无法校验下载脚本。'
        actual=${actual%% *}
        [[ $actual == "$expected" ]] || die '最新版脚本 SHA-256 不匹配，未执行。'
        bash -n "$work/$name" || die '最新版脚本语法检查失败，未执行。'
        say "使用本项目最新 Release：$tag。"
        BBR_DD_RELEASE_SHA256=$expected bash "$work/$name"
    )
    # Never continue into the older menu after the child exits or fails.
    exit "$?"
}
# END RELEASE HELPERS

require_ubuntu() {
    [[ $ID == ubuntu ]] || die '内核安装仅支持 Ubuntu。'
    case "$VERSION_ID" in 24.04|26.04) ;; *) die '内核安装仅支持 Ubuntu 24.04 / 26.04。' ;; esac
    case "$(uname -m)" in x86_64|aarch64) ;; *) die '内核安装仅支持 amd64 / arm64。' ;; esac
}

kernel_preflight() {
    require_ubuntu
    secure_boot_check
    inspect_cloud
    need update-grub; need update-initramfs; need apt-get; need systemctl; need dpkg-deb
    [[ -d /run/systemd/system ]] || die '自动清理需要 systemd。'
    [[ ! -e /var/lib/ubuntu-dd/reinstall-pending ]] || die '已有重装计划，请先在 DD 菜单取消待执行重装。'
    recover_kernel_install
    [[ ! -e $STATE/cleanup-pending && ! -L $STATE/cleanup-pending &&
       ! -e $STATE/cleanup-incomplete && ! -L $STATE/cleanup-incomplete ]] || die '已有待完成的内核检查或清理，请先启动目标内核，再选择菜单“清理其他内核（仅保留当前 BBR）”。'
    [[ -f /boot/grub/grub.cfg ]] || die '未发现 GRUB 配置，暂不支持该引导方式。'
}

prebuilt_arch_check() {
    need dpkg
    [[ $(uname -m) == x86_64 && $(dpkg --print-architecture) == "$PREBUILT_ARCH" ]] ||
        die '本次预编译包仅支持 amd64；arm64 请在“安装 Guard7 R2”中选择源码编译。'
}

prebuilt_resources() {
    local available_kb free_kb path
    available_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    (( available_kb >= 512 * 1024 )) || die '预编译安装至少需要 512 MiB 可用内存。'
    for path in "$STATE" /; do
        free_kb=$(df -Pk "$path" | awk 'END {print $4}')
        (( free_kb >= 2 * 1024 * 1024 )) || die "$path 至少需要 2 GiB 可用空间。"
    done
    free_kb=$(df -Pk /boot | awk 'END {print $4}')
    (( free_kb >= 512 * 1024 )) || die '/boot 至少需要 512 MiB 可用空间。'
}

verify_prebuilt_metadata() {
    local directory=$1 kind file
    for kind in image headers; do
        file=$directory/linux-$kind-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb
        [[ $(dpkg-deb -f "$file" Package) == "linux-$kind-$PREBUILT_RELEASE" &&
           $(dpkg-deb -f "$file" Version) == "$PREBUILT_VERSION" &&
           $(dpkg-deb -f "$file" Architecture) == "$PREBUILT_ARCH" ]] || die "预编译包元数据不匹配：$file。"
    done
}

load_prebuilt_checksums() {
    local manifest image_digest headers_digest url
    PREBUILT_IMAGE_SHA256=; PREBUILT_HEADERS_SHA256=
    manifest=$(mktemp "$STATE/release-checksums.XXXXXX") || die '无法创建发布清单临时文件。'
    url=https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/$PREBUILT_TAG
    if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
        if [[ $BBR_PACKAGE_DIR != /* || ! -d $BBR_PACKAGE_DIR ||
              ! -f $BBR_PACKAGE_DIR/SHA256SUMS || -L $BBR_PACKAGE_DIR/SHA256SUMS ]] ||
           ! cp -- "$BBR_PACKAGE_DIR/SHA256SUMS" "$manifest"; then
            rm -f -- "$manifest"
            die 'BBR_PACKAGE_DIR 必须是含 SHA256SUMS 的本地绝对目录，未安装。'
        fi
    elif ! curl --fail --silent --show-error --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 --max-redirs 5 \
        --connect-timeout 10 --max-time 60 --retry 2 --max-filesize 1048576 \
        --output "$manifest" "$url/SHA256SUMS"; then
        rm -f -- "$manifest"
        die '下载固定版本的内核发布清单失败，未安装。'
    fi
    if ! image_digest=$(release_checksum "$manifest" "linux-image-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb") ||
       ! headers_digest=$(release_checksum "$manifest" "linux-headers-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb"); then
        rm -f -- "$manifest"
        die '发布清单缺少唯一有效的内核包 SHA-256，未安装。'
    fi
    rm -f -- "$manifest"
    PREBUILT_IMAGE_SHA256=$image_digest
    PREBUILT_HEADERS_SHA256=$headers_digest
}

copy_prebuilt_package() (
    local source=$1 destination=$2 expected=$3 actual temporary=''
    trap '[[ -z $temporary ]] || rm -f -- "$temporary"' EXIT
    if [[ -e $destination || -L $destination ]]; then
        [[ -f $destination && ! -L $destination ]] || die '本地内核缓存文件类型异常。'
        actual=$(sha256sum -- "$destination")
        [[ ${actual%% *} == "$expected" ]] || die '本地内核缓存 SHA-256 不匹配，未安装。'
        return
    fi
    [[ -f $source && ! -L $source ]] || die "本地内核包缺失或不是普通文件：$source。"
    temporary=$(mktemp "$destination.local.XXXXXX")
    cp -- "$source" "$temporary"
    actual=$(sha256sum -- "$temporary")
    [[ ${actual%% *} == "$expected" ]] || die '本地内核包 SHA-256 不匹配，未安装。'
    mv -fT -- "$temporary" "$destination"
)

fetch_prebuilt_packages() {
    local directory=$1 image headers url
    [[ $PREBUILT_IMAGE_SHA256 =~ ^[a-f0-9]{64}$ && $PREBUILT_HEADERS_SHA256 =~ ^[a-f0-9]{64}$ ]] ||
        die '尚未取得固定版本的内核包 SHA-256。'
    image=linux-image-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb
    headers=linux-headers-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb
    url=https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/$PREBUILT_TAG
    if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
        copy_prebuilt_package "$BBR_PACKAGE_DIR/$image" "$directory/$image" "$PREBUILT_IMAGE_SHA256"
        copy_prebuilt_package "$BBR_PACKAGE_DIR/$headers" "$directory/$headers" "$PREBUILT_HEADERS_SHA256"
    else
        download_verified "$url/$image" "$directory/$image" "$PREBUILT_IMAGE_SHA256" 1
        download_verified "$url/$headers" "$directory/$headers" "$PREBUILT_HEADERS_SHA256" 1
    fi
    verify_prebuilt_metadata "$directory"
    printf '%s\n' "$PREBUILT_RELEASE" > "$directory/kernel-release"
}

verify_prebuilt_drivers() (
    local directory=$1 staging driver path target
    need modinfo
    staging=$(mktemp -d "$directory/check.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    dpkg-deb -x "$directory/linux-image-${PREBUILT_RELEASE}_${PREBUILT_VERSION}_${PREBUILT_ARCH}.deb" "$staging"
    local -a drivers=(tcp_bbr_guard sch_fq "${NIC_DRIVERS[@]}")
    # 同时检查当前绑定的 PCI / VirtIO / Xen 驱动，覆盖活动磁盘控制器。
    for path in "$SYS_ROOT"/bus/{pci,virtio,xen}/devices/*/driver; do
        [[ -L $path ]] || continue
        if [[ -L $path/module ]]; then target=$(readlink -f "$path/module"); else target=$(readlink -f "$path"); fi
        drivers+=("${target##*/}")
    done
    for driver in "${drivers[@]}"; do
        [[ $driver != unknown ]] || die '无法确定当前设备驱动，未安装预编译内核。'
        modinfo -b "$staging" -k "$PREBUILT_RELEASE" "$driver" >/dev/null ||
            die "预编译内核缺少活动设备/算法驱动 $driver，未安装内核；可在菜单选择源码构建沿用本机配置。"
    done
)

install_prebuilt_kernel() {
    if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
        say "安装 Linux $KERNEL_VERSION + Guard7 R2 实验恢复算法，使用本地预编译包。"
    else
        say "安装 Linux $KERNEL_VERSION + Guard7 R2 实验恢复算法，固定内核包 $PREBUILT_TAG。"
    fi
    say '安装已构建并验收的 Guard7 R2；不包含原版 BBR、BBR3 或旧 WAN 模块。'
    prebuilt_arch_check
    if (( DRY_RUN )); then
        say '[预览] 检查 Ubuntu、Secure Boot、GRUB、实际网卡和安装空间。'
        if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
            say '[预览] 读取本地清单与 image / headers，核对 SHA-256、架构及版本；无需编译。'
        else
            say '[预览] 从固定 GitHub Release 获取校验清单和 image / headers，核对 SHA-256、架构及版本；无需编译。'
        fi
        say "[预览] 安装并选择 $ALGORITHM，检查驱动、initramfs 和 GRUB；重启检查通过后仅保留当前 BBR 内核及其 headers，删除其他内核。"
        return
    fi
    kernel_preflight
    prebuilt_resources
    if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
        say "使用本地预编译包：$BBR_PACKAGE_DIR"
    else
        need curl
    fi
    need sha256sum
    load_prebuilt_checksums
    local directory component
    directory=$STATE
    for component in prebuilt-cache "$PREBUILT_ARCH" "$PREBUILT_RELEASE" "$PREBUILT_IMAGE_SHA256-$PREBUILT_HEADERS_SHA256"; do
        directory=$directory/$component
        [[ ! -L $directory && ( ! -e $directory || -d $directory ) ]] || die '内核缓存目录异常，未覆盖。'
        install -d -m 700 "$directory"
    done
    say "内核缓存目录（同版本重试复用）：$directory"
    fetch_prebuilt_packages "$directory"
    verify_prebuilt_drivers "$directory"
    # 只安装运行和引导依赖；不安装编译器及开发工具链。
    apt-get update
    apt-get install -y --no-remove --no-install-recommends python3 kmod initramfs-tools zstd
    install_built_kernel "$directory"
    if [[ -n ${BBR_PACKAGE_DIR:-} ]]; then
        printf 'package_source=local\narchitecture=%s\n' "$PREBUILT_ARCH" >> "$directory/build-info.txt"
    else
        printf 'release_tag=%s\narchitecture=%s\n' "$PREBUILT_TAG" "$PREBUILT_ARCH" >> "$directory/build-info.txt"
    fi
}

save_bbr_backup() {
    [[ -f $STATE/bbr-backup/complete ]] && return 0
    local tmp
    tmp=$(mktemp -d "$STATE/bbr-backup.XXXXXX")
    sysctl -n net.ipv4.tcp_congestion_control > "$tmp/congestion"
    sysctl -n net.core.default_qdisc > "$tmp/qdisc"
    if [[ -e $SYSCTL_FILE || -L $SYSCTL_FILE ]]; then cp -a -- "$SYSCTL_FILE" "$tmp/sysctl.conf"; fi
    if [[ -e $MODULES_FILE || -L $MODULES_FILE ]]; then cp -a -- "$MODULES_FILE" "$tmp/modules.conf"; fi
    touch "$tmp/complete"
    mv -- "$tmp" "$STATE/bbr-backup"
}

write_bbr_config() (
    # Both same-filesystem temporaries are removed on every failure path.
    local tmp='' modules_tmp='' sysctl_dir modules_dir
    trap 'rm -f -- "$tmp" "$modules_tmp"' EXIT
    sysctl_dir=$(dirname "$SYSCTL_FILE"); modules_dir=$(dirname "$MODULES_FILE")
    install -d "$sysctl_dir" "$modules_dir" || return 1
    tmp=$(mktemp "$sysctl_dir/.bbr-kernel.XXXXXX") || return 1
    modules_tmp=$(mktemp "$modules_dir/.bbr-kernel.XXXXXX") || return 1
    printf '# Managed by bbr-kernel\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = %s\n' "$ALGORITHM" > "$tmp" || return 1
    printf '%s\nsch_fq\n' "$BBR_MODULE" > "$modules_tmp" || return 1
    chmod 644 "$tmp" "$modules_tmp" || return 1
    mv -fT -- "$tmp" "$SYSCTL_FILE" || return 1
    mv -fT -- "$modules_tmp" "$MODULES_FILE" || return 1
)

restore_config_files() {
    local backup=$1
    rm -f -- "$SYSCTL_FILE" "$MODULES_FILE"
    if [[ -e $backup/sysctl.conf || -L $backup/sysctl.conf ]]; then cp -a -- "$backup/sysctl.conf" "$SYSCTL_FILE"; fi
    if [[ -e $backup/modules.conf || -L $backup/modules.conf ]]; then cp -a -- "$backup/modules.conf" "$MODULES_FILE"; fi
}

enable_bbr() (
    if (( DRY_RUN )); then
        say '[预览] 检查当前内核 BBR / fq 支持，备份本工具管理的配置，启用并持久化 BBR + fq。'
        return
    fi
    need sysctl; need modprobe
    modprobe "$BBR_MODULE" || die "无法加载 $BBR_MODULE，请先安装并启动本工具内核。"
    modprobe sch_fq || die '当前内核缺少 fq 模块。'
    [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *" $ALGORITHM "* ]] || die "当前内核不支持 $ALGORITHM。"
    # 回滚到本次操作前的状态；长期 restore 使用首次备份。
    local before old_cc old_qdisc rollback=0 status
    before=$(mktemp -d "$STATE/bbr-transaction.XXXXXX")
    trap 'status=$?; if (( rollback )); then
        restore_config_files "$before" || true
        sysctl -w "net.core.default_qdisc=$old_qdisc" "net.ipv4.tcp_congestion_control=$old_cc" || true
        say "BBR 应用未完成，已尝试恢复修改前的配置与参数。" >&2
    fi; rm -rf -- "$before"; exit "$status"' EXIT
    [[ ! -e $SYSCTL_FILE && ! -L $SYSCTL_FILE ]] || cp -a -- "$SYSCTL_FILE" "$before/sysctl.conf"
    [[ ! -e $MODULES_FILE && ! -L $MODULES_FILE ]] || cp -a -- "$MODULES_FILE" "$before/modules.conf"
    old_cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    old_qdisc=$(sysctl -n net.core.default_qdisc)
    save_bbr_backup
    rollback=1
    write_bbr_config || die '写入 BBR 配置失败。'
    sysctl -w net.core.default_qdisc=fq || die '设置 fq 失败。'
    sysctl -w "net.ipv4.tcp_congestion_control=$ALGORITHM" || die '设置 BBR 失败。'
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "$ALGORITHM" && $(sysctl -n net.core.default_qdisc) == fq ]] || die 'BBR 参数复核失败。'
    printf '%s\n' "$PROFILE" > "$STATE/profile"
    # Read by the EXIT trap after successful verification.
    # shellcheck disable=SC2034
    rollback=0
    say "已启用 $ALGORITHM，默认队列设为 fq。现有网卡队列不强行重建，可重启后检查 tc qdisc show。"
)

restore_bbr() {
    if (( DRY_RUN )); then say '[预览] 恢复首次备份的配置和运行参数，不卸载内核。'; return; fi
    local backup=$STATE/bbr-backup cc qdisc
    [[ -f $backup/complete ]] || die '没有可恢复的 BBR 备份。'
    cc=$(cat "$backup/congestion"); qdisc=$(cat "$backup/qdisc")
    [[ $cc =~ ^[a-zA-Z0-9_]+$ && $qdisc =~ ^[a-zA-Z0-9_]+$ ]] || die '备份参数无效。'
    restore_config_files "$backup"
    sysctl -w "net.core.default_qdisc=$qdisc" "net.ipv4.tcp_congestion_control=$cc"
    say '已恢复首次运行前的配置。此操作不会恢复已经清理的旧内核。'
}

kernel_resources() {
    local mem_kb swap_kb cpu max_jobs free_kb
    mem_kb=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    swap_kb=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)
    (( mem_kb >= 1500000 && mem_kb + swap_kb >= 4000000 )) || die '编译至少需要约 1.5 GB 可用内存，内存 + 可用 swap 合计 4 GB。'
    free_kb=$(df -Pk "$STATE" | awk 'END {print $4}')
    (( free_kb >= 30 * 1024 * 1024 )) || die '编译目录至少需要 30 GiB 可用空间。'
    free_kb=$(df -Pk /boot | awk 'END {print $4}')
    (( free_kb >= 512 * 1024 )) || die '/boot 至少需要 512 MiB 可用空间。'
    cpu=$(nproc)
    max_jobs=$((mem_kb / 2000000)); (( max_jobs > 0 )) || max_jobs=1
    (( max_jobs <= cpu )) || max_jobs=$cpu
    if [[ -z $JOBS ]]; then JOBS=$max_jobs; fi
    (( JOBS <= max_jobs )) || die "当前资源建议最多 $max_jobs 个编译任务，请在菜单中降低编译并发数。"
}

configure_kernel_source() {
    local src=$1
    (
        cd "$src"
        scripts/config --set-str LOCALVERSION "-bbrguard7r2only-${BBR_COMMIT:0:12}" \
            --disable LOCALVERSION_AUTO --enable TCP_CONG_ADVANCED --module TCP_CONG_BBR_GUARD \
            --disable TCP_CONG_BBR --disable TCP_CONG_BBR3 --disable TCP_CONG_BBR_WAN \
            --enable TCP_CONG_CUBIC --enable DEFAULT_CUBIC --set-str DEFAULT_TCP_CONG cubic \
            --enable NET_SCHED --module NET_SCH_FQ --disable DEBUG_INFO \
            --enable NET_VENDOR_GOOGLE --module GVE --enable NET_VENDOR_AMAZON --module ENA_ETHERNET \
            --enable VIRTIO_PCI --module VIRTIO_NET --module VIRTIO_BLK --module SCSI_VIRTIO --module BLK_DEV_NVME \
            --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --disable DEBUG_INFO_DWARF4 --disable DEBUG_INFO_DWARF5 \
            --enable DEBUG_INFO_NONE --disable DEBUG_INFO_BTF --disable DEBUG_INFO_BTF_MODULES \
            --set-str SYSTEM_TRUSTED_KEYS '' --set-str SYSTEM_REVOCATION_KEYS '' \
            --set-str MODULE_SIG_KEY certs/signing_key.pem
        make olddefconfig
        grep -q '^CONFIG_TCP_CONG_BBR_GUARD=m$' .config
        if grep -Eq '^CONFIG_TCP_CONG_(BBR|BBR3|BBR_WAN)=[ym]$' .config; then
            die '原版或旧 WAN 算法仍在构建配置中，已停止。'
        fi
        grep -q '^CONFIG_NET_SCH_FQ=m$' .config
        grep -q '^CONFIG_DEBUG_INFO_NONE=y$' .config
        grep -Eq '^CONFIG_GVE=[ym]$' .config
    )
}

compile_kernel_source() {
    local src=$1 build=$2 log=$3
    (
        configure_kernel_source "$src"
        cd "$src"
        make -j"$JOBS" KDEB_PKGVERSION="$KERNEL_VERSION-guard7r2.1" bindeb-pkg
        # Reused trees may cache the previous release until the build updates it.
        make -s kernelrelease > "$build/kernel-release"
    ) 2>&1 | tee "$log"
}

build_kernel() {
    say "Linux 稳定版 $KERNEL_VERSION + Guard7 R2 实验恢复算法（自定义构建，不自动接收后续安全更新）。"
    if (( DRY_RUN )); then
        say '[预览] 检查 Ubuntu、架构、Secure Boot、GRUB、内存和磁盘空间。'
        say "[预览] 下载并校验 Google BBRv3 源码，沿用当前内核驱动配置，编译 Debian 软件包（并发 ${JOBS:-自动}）。"
        say '[预览] 仅编译 Guard7 R2，禁用原版 BBR / BBR3 和旧 WAN 模块；保留 TCP 基础算法及网卡、磁盘驱动。'
        say '[预览] 安装新内核并设置 GRUB；启动检查通过后仅保留当前 BBR 内核及其 headers，自动删除其他内核。'
        return
    fi
    kernel_preflight
    [[ -r /boot/config-$(uname -r) ]] || die "缺少当前内核配置 /boot/config-$(uname -r)。"
    kernel_resources
    say "使用 $JOBS 个编译任务；首次构建可能需要数十分钟到数小时。"
    apt-get update
    local host_gcc
    case "$(uname -m)" in x86_64) host_gcc=gcc-x86-64-linux-gnu ;; aarch64) host_gcc=gcc-aarch64-linux-gnu ;; esac
    apt-get install -y --no-remove build-essential "$host_gcc" bc bison flex libssl-dev libelf-dev libdw-dev libncurses-dev \
        dwarves rsync cpio kmod xz-utils zstd fakeroot dpkg-dev debhelper python3 curl ca-certificates patch
    local archive=$STATE/linux-$KERNEL_VERSION.tar.xz build src log
    download_verified "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$KERNEL_VERSION.tar.xz" "$archive" "$KERNEL_SHA256" 1
    build=$(mktemp -d "$STATE/build.XXXXXX")
    src=$build/linux
    mkdir "$src"
    log=$build/build.log
    say "编译目录：$build"
    tar -xJf "$archive" --strip-components=1 -C "$src"
    cp "/boot/config-$(uname -r)" "$src/.config"
    apply_google_patch "$src"
    apply_recovery_patch "$src"
    compile_kernel_source "$src" "$build" "$log"
    install_built_kernel "$build"
}

kernel_restore_file() {
    local backup=$1 destination=$2 temporary
    if [[ -e $backup || -L $backup ]]; then
        temporary=$(mktemp "${destination}.restore.XXXXXX") || return 1
        if ! cp -a --remove-destination -- "$backup" "$temporary" ||
           ! mv -fT -- "$temporary" "$destination"; then
            rm -f -- "$temporary"
            return 1
        fi
    else
        rm -f -- "$destination" || return 1
    fi
}

kernel_install_files() {
    local action=$1 transaction=$2 index saved failed=0
    local -a names=(sysctl.conf modules.conf nic-hook kernel-release profile rollback-release cleanup-pending grub-fragment grub.cfg)
    local -a paths=("$SYSCTL_FILE" "$MODULES_FILE" /etc/initramfs-tools/hooks/bbr-cloud-nic
        "$STATE/kernel-release" "$STATE/profile" "$STATE/rollback-release" "$STATE/cleanup-pending"
        /etc/default/grub.d/99-bbr-kernel.cfg /boot/grub/grub.cfg)
    for index in "${!names[@]}"; do
        saved=$transaction/before/${names[$index]}
        if [[ $action == save ]]; then
            [[ ! -e ${paths[$index]} || -f ${paths[$index]} || -L ${paths[$index]} ]] || return 1
            if [[ -e ${paths[$index]} || -L ${paths[$index]} ]]; then
                cp -a -- "${paths[$index]}" "$saved" || return 1
            else
                touch "$saved.absent" || return 1
            fi
        else
            # Once packages can run their hooks, roll back to the explicit
            # verified fallback, never an auto-selected newest kernel.
            if [[ -f $transaction/pinned/ready && ${names[$index]} == grub* ]]; then
                saved=$transaction/pinned/${names[$index]}
            fi
            if [[ ! -e $saved && ! -L $saved && ! -f $saved.absent ]]; then
                say "恢复备份缺失：$saved。" >&2
                failed=1
                continue
            fi
            kernel_restore_file "$saved" "${paths[$index]}" || failed=1
        fi
    done
    return "$failed"
}

recover_kernel_install() {
    local transaction
    [[ -e $STATE/install-pending || -L $STATE/install-pending ]] || return 0
    [[ ! -e /var/lib/ubuntu-dd/reinstall-pending ]] || die '已有 DD 重装计划，请先取消，再恢复内核安装。'
    [[ -f $STATE/install-pending && ! -L $STATE/install-pending ]] || die '安装恢复记录异常，请人工检查。'
    transaction=$(cat "$STATE/install-pending")
    [[ ${transaction%/*} == "$STATE" && ${transaction##*/} =~ ^install\.[a-zA-Z0-9]+$ &&
       -d $transaction && ! -L $transaction && -f $transaction/ready ]] || die '安装恢复目录异常，请人工检查。'
    if [[ ! -f $transaction/complete ]]; then
        kernel_install_files restore "$transaction" || die "恢复未完成，禁止继续安装；请检查 $transaction。"
        say "已恢复上次未完成安装的启动项与配置；原记录保留在 $transaction。"
    fi
    rm -f -- "$STATE/install-pending"
}

finish_kernel_install() {
    local status=$1 transaction=$2
    trap - EXIT INT TERM HUP
    # All recovery steps report failures explicitly; keep the marker when
    # restoration fails so reboot/cleanup cannot treat a partial result as ready.
    set +e
    printf '%s\n' "$status" > "$transaction/exit-status"
    if [[ -f $transaction/complete ]]; then
        rm -f -- "$STATE/install-pending" || exit 1
    else
        (( status != 0 )) || status=1
        if kernel_install_files restore "$transaction"; then
            rm -f -- "$STATE/install-pending"
            say '安装未完成，已恢复启动项和本工具配置；已安装的软件包保留，可处理错误后重试。' >&2
        else
            say '安装未完成且配置恢复失败，保留恢复记录；请勿重启，先修复文件系统或权限后重试。' >&2
        fi
        say "安装阶段和恢复备份：$transaction" >&2
    fi
    exit "$status"
}

install_built_kernel() (
    local build=$1 release previous rollback transaction pending
    # APT treats bare relative paths as package selectors, not local archives.
    build=$(cd -- "$build" && pwd -P) || die '无法访问内核包目录。'
    recover_kernel_install
    release=$(cat "$build/kernel-release")
    [[ $release =~ ^[0-9][a-zA-Z0-9.+~-]+$ ]] || die '待安装内核版本记录无效。'
    previous=$(uname -r)
    rollback=$previous
    # Reinstalling the running release replaces its files too. Require a
    # separately bootable recorded kernel before permitting that operation.
    if [[ $previous == "$release" ]]; then
        [[ -s $STATE/rollback-release ]] || die '重装当前内核前需要另一套已验证的回退内核，未安装软件包。'
        rollback=$(cat "$STATE/rollback-release")
        [[ $rollback != "$release" ]] || die '回退内核不能与待重装内核相同。'
    fi
    verify_rollback_kernel "$rollback"
    local -a images=() headers=() packages=()
    local deb package version
    for deb in "$build"/*.deb; do
        [[ -f $deb ]] || continue
        package=$(dpkg-deb -f "$deb" Package)
        if [[ $package == "linux-image-$release" ]]; then images+=("$deb"); fi
        if [[ $package == "linux-headers-$release" ]]; then headers+=("$deb"); fi
    done
    (( ${#images[@]} == 1 && ${#headers[@]} == 1 )) || die "未找到唯一内核及 headers 包，请检查 $build。"
    packages=("${images[@]}" "${headers[@]}")
    (cd "$build"; sha256sum linux-*.deb > SHA256SUMS)
    version=$(dpkg-deb -f "${images[0]}" Version)
    transaction=$(mktemp -d "$STATE/install.XXXXXX")
    mkdir "$transaction/before" "$transaction/pinned"
    kernel_install_files save "$transaction"
    touch "$transaction/ready"
    trap 'finish_kernel_install $? "$transaction"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    pending=$(mktemp "$STATE/.install-pending.XXXXXX")
    printf '%s\n' "$transaction" > "$pending"
    mv -fT -- "$pending" "$STATE/install-pending"
    printf 'pin-fallback\n' > "$transaction/phase"
    set_new_boot_default "$rollback"
    cp -a /etc/default/grub.d/99-bbr-kernel.cfg "$transaction/pinned/grub-fragment"
    cp -a /boot/grub/grub.cfg "$transaction/pinned/grub.cfg"
    touch "$transaction/pinned/ready"
    printf '%s\n' "$rollback" > "$STATE/rollback-release"
    # Package hooks run update-grub themselves. Keep the verified fallback
    # selected throughout installation, and forbid dependency removals.
    printf 'package-install\n' > "$transaction/phase"
    apt-get install -y --no-remove --reinstall "${packages[@]}"
    [[ -s /boot/vmlinuz-$release && -d /lib/modules/$release ]] || die '内核安装文件不完整。'
    printf 'driver-and-initramfs\n' > "$transaction/phase"
    verify_new_drivers "$release"
    if [[ -f /boot/initrd.img-$release ]]; then update-initramfs -u -k "$release"; else update-initramfs -c -k "$release"; fi
    [[ -s /boot/initrd.img-$release ]] || die '新内核 initramfs 文件缺失或为空。'
    update-grub
    grep -Fq "$release" /boot/grub/grub.cfg || die '新内核未出现在 GRUB 中，请检查引导配置后再重启。'
    verify_rollback_kernel "$rollback"
    printf 'configuration\n' > "$transaction/phase"
    save_bbr_backup
    write_bbr_config
    printf '%s\n' "$release" > "$STATE/kernel-release"
    printf '%s\n' "$PROFILE" > "$STATE/profile"
    printf 'boot-default\n' > "$transaction/phase"
    set_new_boot_default "$release"
    printf 'health-service\n' > "$transaction/phase"
    schedule_cleanup
    printf 'google_commit=%s\nkernel_version=%s\nrelease=%s\npackage_version=%s\nsource_sha256=%s\nguard_revision=7\nprofile=%s\n' "$BBR_COMMIT" "$KERNEL_VERSION" "$release" "$version" "$KERNEL_SHA256" "$PROFILE" > "$build/build-info.txt"
    printf 'complete\n' > "$transaction/phase"
    touch "$transaction/complete"
    say "内核安装完成：$release"
    say "软件包、校验和与日志保存在：$build"
    say '已设置新内核为默认启动项。可在菜单选择“重启系统”；启动后本机健康检查通过才会清理其他内核。'
    say '启动检查通过后仅保留当前 BBR 内核及其 headers，原回退内核也会删除；清理完成后没有备用内核。'
)


# BEGIN CLOUD HELPERS
detect_nics() {
    NIC_NAMES=(); NIC_DRIVERS=(); HAS_GVNIC=0
    local path name driver target
    for path in "$SYS_ROOT"/class/net/*; do
        [[ -e $path/device ]] || continue
        name=${path##*/}
        driver=unknown
        if [[ -L $path/device/driver/module ]]; then
            target=$(readlink -f "$path/device/driver/module"); driver=${target##*/}
        elif [[ -L $path/device/driver ]]; then
            target=$(readlink -f "$path/device/driver"); driver=${target##*/}
        fi
        NIC_NAMES+=("$name"); NIC_DRIVERS+=("$driver")
        [[ $driver != gve ]] || HAS_GVNIC=1
    done
}

detect_cloud() {
    local facts='' file detected=generic
    for file in sys_vendor product_name board_vendor board_name chassis_asset_tag; do
        [[ ! -r $SYS_ROOT/class/dmi/id/$file ]] || facts+=" $(cat "$SYS_ROOT/class/dmi/id/$file")"
    done
    if [[ -r $SYS_ROOT/firmware/devicetree/base/model ]]; then
        facts+=" $(tr -d '\0' < "$SYS_ROOT/firmware/devicetree/base/model")"
    fi
    case "${facts,,}" in
        *google*) detected=gcp ;;
        *oraclecloud*|*oracle*) detected=oci ;;
        *amazon*|*ec2*) detected=aws ;;
    esac
    (( !HAS_GVNIC )) || detected=gcp
    if [[ $CLOUD == auto ]]; then CLOUD=$detected
    elif [[ $detected != generic && $CLOUD != "$detected" && ! ( $CLOUD == lightsail && $detected == aws ) ]]; then
        die "指定平台 $CLOUD 与硬件识别结果 $detected 不一致。"
    fi
}

inspect_cloud() {
    detect_nics
    detect_cloud
    say "平台：$CLOUD；架构：$(uname -m)"
    local i
    for i in "${!NIC_NAMES[@]}"; do say "网卡：${NIC_NAMES[$i]}，驱动：${NIC_DRIVERS[$i]}"; done
    case "$CLOUD" in
        gcp)
            (( ${#NIC_NAMES[@]} > 0 )) || die 'GCP 未识别到物理网卡，请检查 sysfs。'
            for i in "${NIC_DRIVERS[@]}"; do [[ $i != unknown ]] || die 'GCP 存在无法识别的网卡驱动。'; done
            if (( HAS_GVNIC )); then say '已识别 gVNIC（gve）；必须保留 GVE 驱动，不能按 VirtIO 网卡处理。'; fi
            say 'GCP：重装后需复查 Guest Agent、OS Login/元数据 SSH 密钥；本地公钥登录不依赖这些服务。' ;;
        aws|lightsail)
            say 'AWS：按实测驱动保留 ENA / Xen / NVMe 支持。DMI 无法可靠区分 EC2 与 Lightsail。'
            say 'Lightsail 网页终端是 SSH，不是启动救援控制台；准备快照，必要时从快照新建实例或救援磁盘。' ;;
        oci)
            say 'OCI：区分 amd64 与 Ampere arm64；保留 VirtIO/存储驱动，使用 VNIC 的内网地址与 DHCP。'
            say 'OCI：检查 NSG/安全列表、Secure Boot、串行控制台；本工具不支持 iSCSI 启动盘。' ;;
    esac
}

cloud_status() {
    local platform i ipv4 ipv6
    detect_nics
    detect_cloud
    case "$CLOUD" in
        gcp) platform=GCP ;; aws) platform=AWS ;; lightsail) platform='AWS Lightsail' ;;
        oci) platform=OCI ;; *) platform='通用平台' ;;
    esac
    say "运行内核：$(uname -r)"
    say "平台：$platform / $(uname -m)    脚本：$TOOL_VERSION"
    for i in "${!NIC_NAMES[@]}"; do
        if [[ ${NIC_DRIVERS[$i]} == gve ]]; then
            say "网卡：${NIC_NAMES[$i]} / gve（gVNIC）"
        else
            say "网卡：${NIC_NAMES[$i]} / ${NIC_DRIVERS[$i]}"
        fi
    done
    if command -v ip >/dev/null; then
        ipv4=$(ip -o -4 address show scope global 2>/dev/null |
            awk '{printf "%s%s (%s)", sep, $4, $2; sep=", "}' || true)
        ipv6=$(ip -o -6 address show scope global 2>/dev/null |
            awk '{printf "%s%s (%s)", sep, $4, $2; sep=", "}' || true)
        say "网卡 IPv4：${ipv4:-未获取}"
        say "网卡 IPv6：${ipv6:-未获取}"
    fi
}
# END CLOUD HELPERS

# BEGIN GOOGLE PATCH
apply_google_patch() {
    python3 - "$1" <<'PY_GOOGLE'
"""Apply Google's complete BBRv3 patch series to the pinned stable kernel.

The rate sampling, congestion-control callbacks and UAPI changes are required
as well as tcp_bbr3.c. Embedded in bbr.sh along with the original patch.
"""
import base64
import gzip
import hashlib
from pathlib import Path
import re
import subprocess
import sys

PATCH_SHA256 = 'f4098994236209328cbac66e89e4c216aacdce31098b07532f961eecd789c553'
PATCH_DATA = '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'


def apply(root):
    root = Path(root).resolve()
    makefile = (root / 'Makefile').read_text()
    for name, value in [('VERSION', '7'), ('PATCHLEVEL', '3'), ('SUBLEVEL', '5'), ('EXTRAVERSION', '')]:
        match = re.search(r'^' + name + r' =([^\n]*)$', makefile, re.M)
        if not match or match[1].strip() != value:
            raise ValueError('Expected pristine Linux 7.3.5')
    if (root / 'net/ipv4/tcp_bbr3.c').exists():
        raise ValueError('BBRv3 already present; use a clean source tree')
    data = gzip.decompress(base64.b64decode(PATCH_DATA)) if PATCH_DATA else Path(__file__).with_name('google-bbr3.patch').read_bytes()
    if hashlib.sha256(data).hexdigest() != PATCH_SHA256:
        raise ValueError('Google BBRv3 patch checksum mismatch')
    patches = [p for p in re.split(r'(?=^From [a-f0-9]{40} Mon Sep 17)', data.decode(), flags=re.M) if p.strip()]
    if len(patches) != 13:
        raise ValueError('Expected 13 Google BBRv3 patches')
    for number, patch in enumerate(patches, 1):
        print(f'Applying Google BBRv3 patch {number}/13', flush=True)
        subprocess.run(['patch', '--dry-run', '--batch', '--forward', '--fuzz=0', '-p1'], cwd=root, input=patch, text=True, check=True)
        subprocess.run(['patch', '--batch', '--forward', '--fuzz=0', '-p1'], cwd=root, input=patch, text=True, check=True)


if __name__ == '__main__':
    apply(sys.argv[1])
PY_GOOGLE
}
# END GOOGLE PATCH


# BEGIN RECOVERY PATCH
apply_recovery_patch() {
    python3 - "$1" <<'PY_RECOVERY'
"""Generate or integrate a low-queue, sampled-loss recovery TCP kernel module.

The standalone bbrguard module is generated from pinned upstream BBRv3.
Use a matching verified kernel build; do not load on production during trials.
"""
import argparse
import hashlib
from pathlib import Path
import re
import shutil
import tempfile
import sys

SOURCE_SHA256 = '7a8b7e6df08f6815b78b7c03ce48af5829215ab6f7227dadfd980c4f7a4538a9'
BASE_POLICY = r'''/* SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause */
#ifndef BBR_WAN_POLICY_H
#define BBR_WAN_POLICY_H
/* Conservative eligibility gate; low queue delay does NOT prove random loss.
 * min RTT >= 50ms, valid fresh samples, steady state, ECN not negotiated.
 * Subtraction after ordering avoids overflow at large RTT values.
 */
static inline int bbrguard_relax_allowed(unsigned int min_us,
                                      unsigned int srtt_us,
                                      int ecn_seen, int steady, int fresh)
{
    return min_us >= 50000U && min_us != ~0U && srtt_us >= min_us &&
           srtt_us - min_us <= min_us / 8U && !ecn_seen && steady && fresh;
}
#endif
'''

BASE_HELPERS = r'''
#include "tcp_bbr_wan_policy.h"

/* This is an experimental low-queue/high-RTT loss response, not proof that
 * loss is non-congestive. Keep STARTUP, RTO and severe-loss cuts intact.
 * Upstream 2026 BBRv3 omits ECN support. Never relax on ECN-enabled sockets.
 */
static bool bbrguard_relaxed_loss(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbrguard_relax_allowed(bbr->min_rtt_us, tp->srtt_us >> 3,
        tcp_ecn_mode_any(tp),
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
            inet_csk(sk)->icsk_ca_state != TCP_CA_Loss,
        before(tcp_jiffies32, bbr->min_rtt_stamp + 5 * HZ));
}

static u32 bbrguard_loss_limit(const struct sock *sk)
{
    return bbrguard_relaxed_loss(sk) ? BBR_UNIT * 4 / 100 :
                                  bbrguard_param(sk, loss_thresh);
}

'''

def _base_transform(original):
    """Return the pinned base source used by the Guard generator."""
    if hashlib.sha256(original).hexdigest() != SOURCE_SHA256:
        raise ValueError('Expected pinned unmodified BBRv3 input')
    text = original.decode()
    # Rename every identifier containing bbr, including BTF ID set names.
    # Keep bbr3_* callbacks distinct from bbr_* parameters (fast_path and
    # loss_probe_recovery exist in both namespaces in the 2026 source).
    text = re.sub(r'\b[A-Za-z_]\w*\b', lambda m: m[0].replace('bbr3_', 'bbrguard_cc_').replace('bbr3', 'bbrguard').replace('bbr_', 'bbrguard_'), text)
    # These are kernel UAPI definitions, not private implementation names.
    text = text.replace('tcp_bbrguard_info', 'tcp_bbr_info').replace('tcp_bbrguard_phase', 'tcp_bbr_phase')
    text = re.sub(r'(->)bbrguard', r'\1bbr', text)
    marker = 'static bool bbrguard_cc_is_inflight_too_high('
    if text.count(marker) != 1 or text.count('bbrguard_param(sk, loss_thresh)') != 2:
        raise SystemExit('Unexpected BBRv3 loss-response layout')
    # Use one threshold consistently both when deciding excessive loss and
    # when reconstructing the in-flight level at that loss threshold.
    text = text.replace('bbrguard_param(sk, loss_thresh)', 'bbrguard_loss_limit(sk)')
    text = text.replace(marker, BASE_HELPERS + marker)
    old = 'u32 loss_cut = BBR_UNIT - bbrguard_param(sk, beta);'
    if text.count(old) != 1:
        raise SystemExit('Unexpected BBRv3 lower-bound response')
    text = text.replace(old, '''u32 beta = bbrguard_relaxed_loss(sk) ? BBR_UNIT * 15 / 100 :
                                              bbrguard_param(sk, beta);
\tu32 loss_cut = BBR_UNIT - beta;''')
    text = text.replace('MODULE_DESCRIPTION("TCP BBRv3 (Bottleneck Bandwidth and RTT)");',
                        'MODULE_DESCRIPTION("Experimental BBRv3 WAN loss response; A/B testing required");')
    text = text.replace('MODULE_VERSION(__stringify(BBR_VERSION));',
                        'MODULE_VERSION("3-guard7-r2-experimental");\nMODULE_ALIAS("tcp_bbrguard");')
    if '.name\t\t= "bbrguard"' not in text:
        raise SystemExit('Missing unique congestion-control name')
    return text

POLICY = r'''/* SPDX-License-Identifier: GPL-2.0-only OR BSD-2-Clause */
#ifndef BBR_GUARD_POLICY_H
#define BBR_GUARD_POLICY_H
struct bbrguard_gate {
    unsigned int delivered_stamp;
    unsigned int lost_stamp;
    unsigned int sample_stamp;
};
/* Tight absolute queue budget on long paths; use subtraction to avoid wrap. */
static inline int bbrguard_queue_ok(unsigned int min_us, unsigned int rtt,
                                    unsigned int divisor, unsigned int max_us)
{
    unsigned int budget = min_us / divisor;
    if (budget > max_us)
        budget = max_us;
    return min_us >= 50000U && min_us != ~0U && rtt >= min_us &&
           rtt - min_us <= budget;
}
/* Enter recovery after >=128 delivered/lost counter events and <=4% loss.
 * Once qualified, use >=128 events and >=8% loss to revoke the evidence.
 * Unqualified flows retain the >=32/8% early aggregate exit. Queue, ECN,
 * timeout and freshness checks independently control live permission.
 * Counter deltas do not overlap; they are not a claim of independent samples.
 * Unsigned subtraction handles counter wrap; products use 64-bit arithmetic.
 */
static inline unsigned int bbrguard_finish_round(struct bbrguard_gate *g,
        unsigned int delivered, unsigned int lost, unsigned int good_rounds,
        int eligible)
{
    unsigned int good = delivered - g->delivered_stamp;
    unsigned int bad = lost - g->lost_stamp;
    unsigned long long total = (unsigned long long)good + bad;
    int qualified = good_rounds == 3;
    if (eligible && total < 128 &&
        (qualified || total < 32 || (unsigned long long)bad * 100 < total * 8))
        return good_rounds;
    g->delivered_stamp = delivered;
    g->lost_stamp = lost;
    if (!eligible)
        return 0;
    /* Entry and revocation are different statistical questions.
     * The live RTT/ECN/Loss gate still controls permission every ACK.
     */
    if (qualified)
        return (unsigned long long)bad * 100 >= total * 8 ? 0 : 3;
    if ((unsigned long long)bad * 100 > total * 4)
        return 0;
    return bad ? 3 : good_rounds;
}
#endif
'''

HELPERS = r'''
static bool bbrguard_recovery_allowed(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    const struct bbrguard_gate *gate = &bbr->loss_gate;

    return bbr->guard_good_rounds == 3 && !bbr->guard_bad_rtt &&
        bbr->mode == BBR_PROBE_BW &&
        bbr->full_bw_reached && inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !tcp_ecn_mode_any(tp) &&
        tcp_jiffies32 - gate->sample_stamp <= HZ &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U;
}

static void bbrguard_update_gate(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    struct bbrguard_gate *gate = &bbr->loss_gate;
    bool valid = rs->rtt_us >= 0 && !rs->is_ack_delayed;
    bool bad_rtt = false;
    bool allowed = bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        !rs->is_app_limited;

    if (valid) {
        bad_rtt = !bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000);
        /* Keep loss evidence separate from current queue permission.
         * Bad RTT disables recovery immediately; only a trustworthy
         * good sample can clear it. Delayed/missing RTT changes neither. */
        if (!bad_rtt)
            gate->sample_stamp = tcp_jiffies32;
        bbr->guard_bad_rtt = bad_rtt;
    }
    /* Remember observed delivery, not an assumed capacity floor. A single
     * spare bit restricts early exploration to previously larger flows.
     * It never grants current loss/RTT permission or restores old bandwidth.
     */
    if (!bbr->guard_large_sample && allowed && valid && !bad_rtt &&
        rs->delivered >= 128 && rs->interval_us > 0 &&
        (u64)rs->interval_us <= (u64)bbr->min_rtt_us * 2)
        bbr->guard_large_sample = 1;
    if (!allowed || tcp_jiffies32 - gate->sample_stamp > HZ ||
        bbr->min_rtt_us < 50000U || bbr->min_rtt_us == ~0U) {
        bbr->guard_good_rounds = 0;
        gate->delivered_stamp = tp->delivered;
        gate->lost_stamp = tp->lost;
        /* Discard loss evidence on expired samples or excluded states. */
        return;
    }
    if (!bbr->round_start)
        return;
    bbr->guard_good_rounds = bbrguard_finish_round(gate, tp->delivered, tp->lost,
        bbr->guard_good_rounds,
        tcp_jiffies32 - gate->sample_stamp <= HZ);
}

'''


# Bounded early exploration requires observed larger delivery on this socket.
EARLY_GROWTH = r'''/* Small, ACK-funded exploration, without granting loss qualification. */
static bool bbrguard_early_probe(const struct sock *sk,
                                 const struct rate_sample *rs)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbr->guard_large_sample && bbr->inflight_hi < 64 && tp->is_cwnd_limited &&
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        !bbr->guard_bad_rtt && inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !tcp_ecn_mode_any(tp) && !rs->is_app_limited && !rs->is_ack_delayed &&
        rs->acked_sacked && !rs->losses && !rs->lost && rs->rtt_us >= 0 &&
        bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000) &&
        tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;
}

static void bbrguard_cc_probe_inflight_hi_upward(struct sock *sk,
					  const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct bbrguard *bbr = inet_csk_ca(sk);
	u32 delta;

	if (!tp->is_cwnd_limited || tcp_snd_cwnd(tp) < bbr->inflight_hi)
		return;  /* not fully using inflight_hi, so don't grow it */

    if (bbrguard_early_probe(sk, rs)) {
        delta = min(rs->acked_sacked, 64U - bbr->inflight_hi);
        bbr->inflight_hi += delta;
        bbr->bw_probe_up_acks = 0;
        if (delta)
            bbr->try_fast_path = 0;
        if (bbr->round_start)
            bbrguard_cc_raise_inflight_hi_slope(sk);
        return;
    }

	/* For each bw_probe_up_cnt packets ACKed, increase inflight_hi by 1. */
	bbr->bw_probe_up_acks += rs->acked_sacked;
	if (bbr->bw_probe_up_acks >=  bbr->bw_probe_up_cnt) {
		delta = bbr->bw_probe_up_acks / bbr->bw_probe_up_cnt;
		bbr->bw_probe_up_acks -= delta * bbr->bw_probe_up_cnt;
		bbr->inflight_hi += delta;
		bbr->try_fast_path = 0;  /* Need to update cwnd */
	}

	if (bbr->round_start)
		bbrguard_cc_raise_inflight_hi_slope(sk);
}
'''

WINDOW_PACING = r'''
/* Allow a currently allocated small window to be paced within its sampled
 * RTT. This does not restore historic bandwidth or increase cwnd/inflight_hi.
 * Keep ACK, queue, loss, ECN, timeout and freshness gates live on every ACK.
 */
static void bbrguard_pace_window(struct sock *sk, const struct rate_sample *rs)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    u64 budget_bw;
    unsigned long rate;

    bbr->guard_pacing_boost = 0;
    if (!(bbr->guard_large_sample && bbr->inflight_hi < 64 &&
          bbr->mode == BBR_PROBE_BW && bbr->cycle_idx == BBR_BW_PROBE_UP &&
          bbr->full_bw_reached && !bbr->guard_bad_rtt &&
          inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
          !rs->is_app_limited && !rs->is_ack_delayed && rs->acked_sacked &&
          !rs->losses && !rs->lost && rs->rtt_us >= 0 &&
          bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000) &&
          tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ))
        return;
    budget_bw = (u64)min(tcp_snd_cwnd(tp), bbr->inflight_hi) * BW_UNIT;
    do_div(budget_bw, (u32)rs->rtt_us);
    rate = bbrguard_cc_bw_to_pacing_rate(sk, budget_bw, BBR_UNIT);
    if (rate > READ_ONCE(sk->sk_pacing_rate)) {
        WRITE_ONCE(sk->sk_pacing_rate, rate);
        bbr->guard_pacing_boost = 1;
    }
}

'''

TINY_LOSS = r'''/* One tiny overlapping loss sample is not full-window evidence.
 * Limit this exception to the explicit <=64-packet exploration budget.
 */
static bool bbrguard_tiny_single_loss(const struct sock *sk,
                                     const struct rate_sample *rs)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    return bbr->guard_large_sample && rs->lost == 1 &&
        rs->tx_in_flight >= 5 && rs->tx_in_flight < 32 &&
        bbr->inflight_hi < 64 && bbr->mode == BBR_PROBE_BW &&
        bbr->cycle_idx == BBR_BW_PROBE_UP && bbr->full_bw_reached &&
        !bbr->guard_bad_rtt && !tcp_ecn_mode_any(tp) &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss &&
        !rs->is_app_limited && !rs->is_ack_delayed &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U &&
        tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;
}
'''


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Unexpected source anchor: ' + old[:90])
    return text.replace(old, new)


RECOVERY_CONTEXT = r'''static bool bbrguard_recovery_context(const struct sock *sk)
{
    const struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);

    /* Socket-local state cannot change within this decision. Freshness
     * remains a separate volatile clock read at each original boundary. */
    return bbr->guard_good_rounds == 3 && !bbr->guard_bad_rtt &&
        bbr->mode == BBR_PROBE_BW && bbr->full_bw_reached &&
        inet_csk(sk)->icsk_ca_state != TCP_CA_Loss && !tcp_ecn_mode_any(tp) &&
        bbr->min_rtt_us >= 50000U && bbr->min_rtt_us != ~0U;
}

'''


DRAIN_POLICY = r'''
/* Two min-RTT time windows avoid waiting for queue-inflated packet rounds.
 * The second window's maximum delivery rate becomes a frozen drain target.
 * Confirmation state and drain state share two u32 fields (8 bytes total).
 */
static void bbrguard_update_drain(struct sock *sk, const struct rate_sample *rs,
                                 const struct bbrguard_context *ctx)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    const struct tcp_sock *tp = tcp_sk(sk);
    u32 rtt = tp->srtt_us >> 3;
    u32 minimum = bbr->min_rtt_us;
    u32 now = (u32)tp->tcp_mstamp;
    bool valid = rs->acked_sacked && rs->rtt_us >= 0 &&
                 !rs->is_ack_delayed && rs->interval_us > 0 && ctx->sample_bw;

    if ((bbr->mode != BBR_PROBE_BW && bbr->mode != BBR_PROBE_RTT) ||
        inet_csk(sk)->icsk_ca_state == TCP_CA_Loss || tcp_ecn_mode_any(tp) ||
        (!bbr->guard_drain_active && rs->is_app_limited) || minimum < 50000U || minimum > 1000000U) {
        if (bbr->guard_drain_active)
            bbr->try_fast_path = 0;
        bbr->guard_stamp = bbr->guard_drain_bw = 0;
        bbr->guard_drop_rounds = bbr->guard_clear_rounds = 0;
        bbr->guard_drain_active = 0;
        return;
    }
    /* PROBE_RTT owns cwnd while active. Preserve our target for its return,
     * but never begin confirmation or apply a second cwnd policy there.
     * full_bw_reached is also reset by PROBE_UP, so mode is the startup gate.
     */
    if (bbr->mode == BBR_PROBE_RTT) {
        bbr->guard_drop_rounds = 0;
        if (!bbr->guard_drain_active)
            bbr->guard_drain_bw = 0;
        return;
    }
    if (!valid)
        return;
    if (bbr->guard_drain_active) {
        /* Once BBR's own maximum has caught up, its normal model owns pacing.
         * This also prevents a stale diagnostic/cap after queue-based exit
         * is prevented by BBR's normal two-BDP cwnd.
         */
        if (bbrguard_cc_max_bw(sk) <= bbr->guard_drain_bw) {
            bbr->guard_drain_active = 0;
            bbr->guard_drain_bw = 0;
            bbr->guard_clear_rounds = 0;
            bbr->try_fast_path = 0;
            return;
        }
        if (rtt >= minimum && rtt - minimum <= max(minimum / 8U, 5000U)) {
            if (!bbr->guard_clear_rounds) {
                bbr->guard_clear_rounds = 1;
                bbr->guard_stamp = now;
            } else if ((u32)(now - bbr->guard_stamp) >= minimum * 2U) {
                bbr->guard_drain_active = 0;
                bbr->guard_drain_bw = 0;
                bbr->guard_clear_rounds = 0;
                bbr->try_fast_path = 0;
            }
        } else {
            bbr->guard_clear_rounds = 0;
        }
        return;
    }
    if (ctx->sample_bw > bbrguard_cc_max_bw(sk) / 2U || rtt < minimum ||
        rtt - minimum < max(minimum / 4U, 10000U)) {
        bbr->guard_drop_rounds = 0;
        bbr->guard_drain_bw = 0;
        return;
    }
    if (!bbr->guard_drop_rounds || (u32)(now - bbr->guard_stamp) > minimum * 4U) {
        bbr->guard_stamp = now;
        bbr->guard_drain_bw = ctx->sample_bw;
        bbr->guard_drop_rounds = 1;
        return;
    }
    bbr->guard_drain_bw = max(bbr->guard_drain_bw, ctx->sample_bw);
    if ((u32)(now - bbr->guard_stamp) >= minimum) {
        if (bbr->guard_drop_rounds == 1) {
            bbr->guard_drop_rounds = 2;
            bbr->guard_stamp = now;
            bbr->guard_drain_bw = ctx->sample_bw;
        } else {
            bbr->guard_drop_rounds = 0;
            bbr->guard_drain_active = 1;
            bbr->guard_clear_rounds = 0;
            bbr->try_fast_path = 0;
        }
    }
}

static void bbrguard_apply_drain(struct sock *sk)
{
    struct bbrguard *bbr = inet_csk_ca(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    u64 window;
    u32 cap;
    unsigned long rate;

    if (!bbr->guard_drain_active)
        return;
    if (bbr->mode != BBR_PROBE_BW)
        return;
    rate = bbrguard_cc_bw_to_pacing_rate(sk, bbr->guard_drain_bw,
                                       BBR_UNIT * 7 / 8);
    WRITE_ONCE(sk->sk_pacing_rate, min(READ_ONCE(sk->sk_pacing_rate), rate));
    window = (u64)bbr->guard_drain_bw * bbr->min_rtt_us;
    window = (window >> BW_SCALE) * 5 / 4 + 4;
    cap = max_t(u32, 4, min_t(u64, window, U32_MAX));
    tcp_snd_cwnd_set(tp, min(tcp_snd_cwnd(tp), cap));
    bbr->guard_pacing_boost = 0;
}

'''


def add_drain_policy(text):
    """Add a bounded drain without changing the original BBR bandwidth model."""
    text = once(text, '\t\tunused_4:6;\n',
                '\t\tguard_drop_rounds:2,\n\t\tguard_clear_rounds:2,\n'
                '\t\tguard_drain_active:1,\n\t\tunused_4:1;\n')
    text = once(text, '\tstruct bbrguard_gate loss_gate;\n',
                '\tstruct bbrguard_gate loss_gate;\n\tu32 guard_stamp;\n\tu32 guard_drain_bw;\n')
    text = once(text, '__bpf_kfunc static void bbrguard_cc_main(',
                DRAIN_POLICY + '__bpf_kfunc static void bbrguard_cc_main(')
    text = once(text, '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);',
                '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);\n\tbbrguard_update_drain(sk, rs, &ctx);')
    text = once(text, '\tif (!bbr->guard_pacing_boost &&',
                '\tif (!bbr->guard_pacing_boost && !bbr->guard_drain_active &&')
    text = once(text, '\tbbrguard_pace_window(sk, rs);',
                '\tbbrguard_pace_window(sk, rs);\n\tbbrguard_apply_drain(sk);')
    reset = ('\tbbr->guard_stamp = bbr->guard_drain_bw = 0;\n'
             '\tbbr->guard_drain_active = 0;\n'
             '\tbbr->guard_drop_rounds = bbr->guard_clear_rounds = 0;\n')
    text = once(text, '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));',
                reset + '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));')
    text = once(text, '\tif (new_state == TCP_CA_Loss) {',
                '\tif (new_state == TCP_CA_Loss) {\n' +
                ''.join('\t' + line + '\n' for line in reset.splitlines()).rstrip('\n'))
    text = once(text, '\tbbr->idle_restart = 1;', reset + '\tbbr->idle_restart = 1;')
    return once(text, '(bbr->guard_large_sample << 4);',
                '(bbr->guard_large_sample << 4) | (bbr->guard_drain_active ? 32 : 0);')


def generate(source, output):
    text = _base_transform(source.read_bytes())
    legacy = BASE_HELPERS
    text = once(text, legacy, HELPERS + legacy)
    text = once(text, '/* BBRv3 congestion control block */',
                '#include "tcp_bbr_guard_policy.h"\n\n/* BBRv3 congestion control block */')
    text = once(text, '\t\tunused_4:11;\n};',
                '\t\tguard_good_rounds:2,\n\t\tguard_bad_rtt:1,\n'
                '\t\tguard_large_sample:1,\n\t\tunused_4:7;\n\tstruct bbrguard_gate loss_gate;\n};')
    text = once(text, '\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);',
                '\tbbrguard_update_gate(sk, rs);\n\tbbrguard_cc_calculate_bw_sample(sk, rs, &ctx);')
    text = once(text, '\tbbr->initialized = 1;',
                '\tmemset(&bbr->loss_gate, 0, sizeof(bbr->loss_gate));\n'
                '\tbbr->loss_gate.delivered_stamp = tp->delivered;\n'
                '\tbbr->loss_gate.lost_stamp = tp->lost;\n'
                '\tbbr->guard_good_rounds = 0;\n\tbbr->guard_bad_rtt = 0;\n\tbbr->guard_large_sample = 0;\n\tbbr->initialized = 1;')
    text = once(text, '\t*is_loss_too_high = 0;\n',
                '\t*is_loss_too_high = 0;\n'
                '\t/* No loss evidence: avoid all recovery eligibility checks. */\n'
                '\tif (rs->lost <= 0 || !rs->tx_in_flight)\n'
                '\t\treturn false;\n'
                '\t/* Qualified short samples overlap; revoke on a full observation,\n'
                '\t * or an immediate catastrophic short signal. Unqualified behavior is\n'
                '\t * unchanged, and queue/ECN/RTO permission is still checked below.\n'
                '\t */\n'
                '\tif ((rs->tx_in_flight >= 128 &&\n'
                '\t     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8) ||\n'
                '\t    (rs->tx_in_flight >= 32 &&\n'
                '\t     (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 25)) {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tbbr->guard_good_rounds = 0;\n'
                '\t} else if (!bbrguard_recovery_context(sk)) {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tif (rs->tx_in_flight >= 32 &&\n'
                '\t\t    (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)\n'
                '\t\t\tbbr->guard_good_rounds = 0;\n'
                '\t} else {\n'
                '\t\tstruct bbrguard *bbr = inet_csk_ca(sk);\n'
                '\t\tbool fresh = tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ;\n'
                '\t\tif (!fresh && rs->tx_in_flight >= 32 &&\n'
                '\t\t    (u64)rs->lost * 100 >= (u64)rs->tx_in_flight * 8)\n'
                '\t\t\tbbr->guard_good_rounds = 0;\n'
                '\t\telse if (tcp_jiffies32 - bbr->loss_gate.sample_stamp <= HZ)\n'
                '\t\t\treturn false;\n'
                '\t}\n')
    text = once(text, '\t/* Loss response. */\n\tif (bbr->loss_in_round) {',
                '\t/* Repeated low-queue random loss must not repeatedly collapse\n'
                '\t * the short-term model. A guarded refill restores old bounds. */\n'
                '\tif (bbrguard_recovery_allowed(sk))\n\t\treturn;\n\n'
                '\t/* Loss response. */\n\tif (bbr->loss_in_round) {')
    text = once(text, '\tif (bbrguard_cc_has_elapsed_in_phase(sk, bbr->probe_wait_us) ||',
                '\tif ((bbrguard_recovery_allowed(sk) &&\n'
                '\t     bbrguard_cc_has_elapsed_in_phase(sk, max(500000U, min(bbr->min_rtt_us, 1000000U) * 4))) ||\n'
                '\t    bbrguard_cc_has_elapsed_in_phase(sk, bbr->probe_wait_us) ||')
    text = once(text, '\t\tif (bbr->prev_probe_too_high &&\n\t\t    inflight >= bbr->inflight_hi) {',
                '\t\tif (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&\n'
                '\t\t    inflight >= bbr->inflight_hi) {')
    text = once(text, '\tif (new_state == TCP_CA_Loss) {',
                '\tif (new_state == TCP_CA_Loss) {\n\t\tbbr->guard_good_rounds = 0;\n'
                '\t\tbbr->guard_bad_rtt = 1;')
    # Replace only the pinned growth body; large-window slope remains upstream.
    match = re.search(r'^static void bbrguard_cc_probe_inflight_hi_upward\([^;]+?\n\{', text, re.M)
    if match is None:
        raise ValueError('Missing inflight growth function')
    end = text.index('\n}\n', match.start()) + 3
    text = once(text, text[match.start():end], EARLY_GROWTH.rstrip() + '\n')
    text = once(text, 'static bool bbrguard_cc_is_inflight_too_high(',
                TINY_LOSS + '\n' + RECOVERY_CONTEXT + 'static bool bbrguard_cc_is_inflight_too_high(')
    text = once(text, '\n\tif (rs->lost > 0 && rs->tx_in_flight) {',
                '\n\tif (bbrguard_tiny_single_loss(sk, rs))\n\t\treturn false;\n'
                '\n\tif (rs->lost > 0 && rs->tx_in_flight) {')
    text = once(text, 'if ((bbrguard_recovery_allowed(sk) &&',
                'if (((bbrguard_recovery_allowed(sk) || bbrguard_early_probe(sk, rs)) &&')
    text = once(text, 'if (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&',
                'if (bbr->prev_probe_too_high && !bbrguard_recovery_allowed(sk) &&\n'
                '            !bbrguard_early_probe(sk, rs) &&')
    text = once(text, '\t\tbbrguard_info->bbr_version\t\t= (__u8)BBR_VERSION;',
                '\t\tbbrguard_info->bbr_version\t\t= (__u8)BBR_VERSION;\n'
                '\t\t/* Experimental diagnostic marker, only for bbrguard. */\n'
                '\t\tbbrguard_info->unused1 = 0x80 | bbr->guard_good_rounds |\n'
                '\t\t\t(bbr->guard_bad_rtt << 2) | (bbrguard_recovery_allowed(sk) << 3) |\n\t\t\t(bbr->guard_large_sample << 4);')
    # A stale small-window bandwidth estimate must not prevent using the
    # window already granted by ACK-funded growth. Keep the override ephemeral.
    text = once(text, '\t\tguard_large_sample:1,\n\t\tunused_4:7;',
                '\t\tguard_large_sample:1,\n\t\tguard_pacing_boost:1,\n\t\tunused_4:6;')
    text = once(text, '\tbbr->guard_large_sample = 0;\n',
                '\tbbr->guard_large_sample = 0;\n\tbbr->guard_pacing_boost = 0;\n')
    text = once(text, '__bpf_kfunc static void bbrguard_cc_main(',
                WINDOW_PACING + '__bpf_kfunc static void bbrguard_cc_main(')
    text = once(text, '\tif (bbrguard_cc_fast_path(sk, &update_model, rs, &ctx))',
                '\tif (!bbr->guard_pacing_boost &&\n'
                '\t    bbrguard_cc_fast_path(sk, &update_model, rs, &ctx))')
    text = once(text, '\tbbrguard_cc_bound_cwnd_for_inflight_model(sk);\n\nout:',
                '\tbbrguard_cc_bound_cwnd_for_inflight_model(sk);\n'
                '\tbbrguard_pace_window(sk, rs);\n\nout:')
    text = once(text, '            !bbrguard_early_probe(sk, rs) &&\n', '            !bbrguard_early_probe(sk, rs) &&\n            /* Preserve an already accepted bounded single-loss sample\n             * across the previous-limit heuristic. Loss classification and\n             * clean-ACK pacing remain unchanged. */\n            !(bbrguard_tiny_single_loss(sk, rs) && tp->is_cwnd_limited &&\n              rs->acked_sacked && rs->losses >= 0 && rs->losses <= 1 &&\n              rs->rtt_us >= 0 &&\n              bbrguard_queue_ok(bbr->min_rtt_us, rs->rtt_us, 32, 2000)) &&\n')
    if not re.search(r'\.name\s*= "bbrguard"', text):
        raise ValueError('Missing isolated algorithm name')
    text = add_drain_policy(text)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'tcp_bbr_guard.c').write_text(text)
    (output / 'tcp_bbr_guard_policy.h').write_text(POLICY)
    (output / 'tcp_bbr_wan_policy.h').write_text(BASE_POLICY)
    (output / 'Makefile').write_text('obj-m += tcp_bbr_guard.o\n')


def apply_kernel_tree(root):
    """Add an opt-in module without changing old WAN sources or TCP ABI."""
    root = root.resolve()
    makefile = (root / 'Makefile').read_text()
    for name, value in [('VERSION', '7'), ('PATCHLEVEL', '3'), ('SUBLEVEL', '5')]:
        if not re.search(r'^' + name + r' = ' + value + r'$', makefile, re.M):
            raise ValueError('Expected Linux 7.3.5 kernel tree')
    ipv4 = root / 'net/ipv4'
    files = ['tcp_bbr_guard.c', 'tcp_bbr_guard_policy.h', 'tcp_bbr_guard_legacy.h']
    config, build = (ipv4 / 'Kconfig').read_text(), (ipv4 / 'Makefile').read_text()
    if any((ipv4 / name).exists() for name in files) or 'TCP_CONG_BBR_GUARD' in config + build:
        raise ValueError('Recovery module already present; use an unmodified tree')
    if config.count('config TCP_CONG_BBR3\n') != 1:
        raise ValueError('Missing unique BBRv3 Kconfig anchor')
    with tempfile.TemporaryDirectory(prefix='bbrguard-tree-') as temporary:
        output = Path(temporary) / 'module'
        generate(ipv4 / 'tcp_bbr3.c', output)
        source = (output / 'tcp_bbr_guard.c').read_text().replace(
            '"tcp_bbr_wan_policy.h"', '"tcp_bbr_guard_legacy.h"')
        (ipv4 / 'tcp_bbr_guard.c').write_text(source)
        shutil.copyfile(output / 'tcp_bbr_guard_policy.h', ipv4 / 'tcp_bbr_guard_policy.h')
        shutil.copyfile(output / 'tcp_bbr_wan_policy.h', ipv4 / 'tcp_bbr_guard_legacy.h')
    option = ('config TCP_CONG_BBR_GUARD\n'
              '\ttristate "Experimental BBRv3 guarded recovery"\n'
              '\tdepends on TCP_CONG_ADVANCED\n'
              '\thelp\n\t  Separate bbrguard module for controlled WAN recovery testing.\n\n')
    (ipv4 / 'Kconfig').write_text(config.replace('config TCP_CONG_BBR3\n', option + 'config TCP_CONG_BBR3\n'))
    (ipv4 / 'Makefile').write_text(build + '\nobj-$(CONFIG_TCP_CONG_BBR_GUARD) += tcp_bbr_guard.o\n')
apply_kernel_tree(Path(sys.argv[1]))
PY_RECOVERY
}
# END RECOVERY PATCH

select_profile() {
    [[ $PROFILE == recovery ]] || die '本版本仅使用 Guard；请在菜单启用实验恢复算法后再清理旧内核。'
    ALGORITHM=bbrguard
    BBR_MODULE=tcp_bbr_guard
}

verify_new_drivers() {
    local release=$1 driver
    for driver in "${NIC_DRIVERS[@]}"; do
        [[ $driver != unknown ]] || die '无法确定当前网卡驱动，不设置新内核启动项。'
        modinfo -k "$release" "$driver" >/dev/null || die "新内核缺少当前网卡驱动 $driver。"
    done
    for driver in tcp_bbr_guard sch_fq; do
        modinfo -k "$release" "$driver" >/dev/null || die "新内核缺少 $driver。"
    done
    # initramfs 默认未必包含网卡。将实际网卡模块加入独立 hook，供早期网络使用。
    local hook=/etc/initramfs-tools/hooks/bbr-cloud-nic
    install -d /etc/initramfs-tools/hooks
    {
        cat <<'HOOK'
#!/bin/sh
case "$1" in prereqs) exit 0 ;; esac
. /usr/share/initramfs-tools/hook-functions
HOOK
        for driver in "${NIC_DRIVERS[@]}"; do
            [[ $driver =~ ^[a-zA-Z0-9_]+$ ]] || die '网卡驱动名称非法。'
            printf 'manual_add_modules %s\n' "$driver"
        done
    } > "$hook"
    chmod 755 "$hook"
}

grub_entry_for() {
    python3 - "$1" "${2:-/boot/grub/grub.cfg}" <<'PY_GRUB'
import pathlib, re, sys
release, file = sys.argv[1:]
text = pathlib.Path(file).read_text()
entries = set(re.findall(r"['\"](gnulinux-" + re.escape(release) + r"-advanced-[^'\"]+)['\"]", text))
if len(entries) != 1:
    raise SystemExit('Cannot identify exactly one GRUB entry for new kernel')
entry = entries.pop()
suffix = entry.split('-advanced-', 1)[1]
submenu = 'gnulinux-advanced-' + suffix
if not re.search(r"['\"]" + re.escape(submenu) + r"['\"]", text):
    raise SystemExit('Missing GRUB advanced submenu')
print(submenu + '>' + entry)
PY_GRUB
}

write_grub_default_config() {
    # Ubuntu cloud images may otherwise skip the initramfs containing our disk/NIC modules.
    printf 'GRUB_DEFAULT="%s"\nGRUB_SAVEDEFAULT=false\nGRUB_TIMEOUT_STYLE=menu\nGRUB_TIMEOUT=5\nGRUB_FORCE_PARTUUID=""\n' "$1" > "$2"
}

set_new_boot_default() {
    local release=$1 entry temporary
    entry=$(grub_entry_for "$release")
    [[ $entry =~ ^[a-zA-Z0-9._+~\>:-]+$ ]] || die 'GRUB 启动项包含意外字符。'
    install -d /etc/default/grub.d
    temporary=$(mktemp /etc/default/grub.d/.bbr-kernel.XXXXXX)
    if ! write_grub_default_config "$entry" "$temporary" ||
       ! chmod 644 "$temporary" ||
       ! mv -fT -- "$temporary" /etc/default/grub.d/99-bbr-kernel.cfg; then
        rm -f -- "$temporary"
        die '写入 GRUB 启动配置失败。'
    fi
    update-grub
    grep -Fq "set default=\"$entry\"" /boot/grub/grub.cfg || die '其他 GRUB 配置覆盖了新默认项，请修正后再重启。'
    if grep -Fq 'attempting initrdless boot.' /boot/grub/grub.cfg; then
        die 'GRUB 仍启用了无 initramfs 启动，请修正云镜像引导覆盖项后再重启。'
    fi
}

schedule_cleanup() {
    install -d /usr/local/libexec
    install -m 700 "${BASH_SOURCE[0]}" /usr/local/libexec/bbr-kernel
    cat > /etc/systemd/system/bbr-kernel-cleanup.service <<'EOF'
[Unit]
Description=Verify running BBR kernel and remove all other kernels
Wants=network-online.target
After=network-online.target ssh.service
ConditionPathExists=/var/lib/bbr-kernel/cleanup-pending

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/bbr-kernel --internal-cleanup
TimeoutStartSec=30min
EOF
    cat > /etc/systemd/system/bbr-kernel-cleanup.timer <<'EOF'
[Unit]
Description=Retry BBR kernel health check after boot

[Timer]
OnBootSec=3min
OnUnitActiveSec=10min
Unit=bbr-kernel-cleanup.service

[Install]
WantedBy=timers.target
EOF
    touch "$STATE/cleanup-pending"
    systemctl daemon-reload
    systemctl enable bbr-kernel-cleanup.timer
}

is_kernel_package() {
    local name=${1%%:*}
    case "$name" in
        linux-image-[0-9]*|linux-image-unsigned-[0-9]*|linux-modules-[0-9]*|linux-modules-extra-[0-9]*|linux-headers-[0-9]*|linux-tools-[0-9]*) return 0 ;;
    esac
    [[ $name =~ ^linux-(image-|headers-|tools-)?(generic|virtual|aws|gcp|oracle|azure|lowlatency)(-[a-zA-Z0-9.+-]+)?$ ]]
}

verify_rollback_kernel() {
    local release=$1
    [[ $release =~ ^[0-9][a-zA-Z0-9.+~-]+$ ]] || die '回退内核记录无效，不清理旧内核。'
    [[ -s /boot/vmlinuz-$release && -s /boot/initrd.img-$release && -d /lib/modules/$release ]] || die '回退内核启动文件或模块不完整，不清理旧内核。'
    [[ $(dpkg-query -W -f='${db:Status-Status}' "linux-image-$release" 2>/dev/null) == installed ||
       $(dpkg-query -W -f='${db:Status-Status}' "linux-image-unsigned-$release" 2>/dev/null) == installed ]] || die '回退内核软件包未安装，不清理旧内核。'
    grub_entry_for "$release" >/dev/null || die '回退内核缺少唯一 GRUB 启动项，不清理旧内核。'
}

kernel_package_for_release() {
    local name=${1%%:*} release=$2 abi
    case "$name" in
        linux-image-"$release"|linux-image-unsigned-"$release"|linux-modules-"$release"|linux-modules-extra-"$release"|linux-headers-"$release"|linux-tools-"$release"|linux-headers-"${release%-*}"|linux-tools-"${release%-*}") return 0 ;;
    esac
    # Ubuntu cloud/HWE kernels may put shared headers and tools in source-
    # flavored packages (e.g. linux-gcp-7.0-headers-7.0.0-1017). Preserve all
    # such packages for this exact ABI, including flavors ending in -64k.
    if [[ $release =~ ^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)- ]]; then
        abi=${BASH_REMATCH[1]}
        case "$name" in
            linux-*-headers-"$abi"|linux-*-tools-"$abi") return 0 ;;
        esac
    fi
    return 1
}

purge_old_kernel_packages() {
    local release=$1 name state simulation line package inventory
    local -a old_packages=() protected_packages=()
    inventory=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 'linux-*') || die '无法读取内核软件包清单。'
    while IFS=$'\t' read -r name state; do
        [[ $state == installed ]] || continue
        package=${name%%:*}
        if kernel_package_for_release "$package" "$release"; then
            protected_packages+=("$name")
            continue
        fi
        if is_kernel_package "$package"; then old_packages+=("$name"); fi
    done <<< "$inventory"
    (( ${#protected_packages[@]} )) || die '没有找到需要保留的内核包。'
    if (( ! ${#old_packages[@]} )); then
        apt-mark manual "${protected_packages[@]}"
        say '没有其他内核包需要卸载。'
        return 0
    fi
    say "准备清理：${old_packages[*]}"
    simulation=$(apt-get --simulate purge -- "${old_packages[@]}") || die '旧内核清理预演失败。'
    while read -r line name _; do
        [[ $line != Inst ]] || die '清理预演将安装其他软件包，已停止。'
        [[ $line == Remv || $line == Purg ]] || continue
        package=${name%%:*}
        if kernel_package_for_release "$package" "$release"; then
            die '清理会影响当前 BBR 内核及其配套包，已停止。'
        fi
        is_kernel_package "$package" || die "清理会连带删除非内核包 $package，已停止。"
    done <<< "$simulation"
    apt-mark manual "${protected_packages[@]}"
    apt-get purge -y -- "${old_packages[@]}"
}

verify_running_kernel_files() {
    local release=$1 kind driver
    [[ $(uname -r) == "$release" && -s /boot/vmlinuz-$release && -s /boot/initrd.img-$release &&
       -d /lib/modules/$release ]] || die '当前内核、启动文件或模块目录异常，不清理其他内核。'
    for kind in image headers; do
        [[ $(dpkg-query -W -f='${db:Status-Status}' "linux-$kind-$release") == installed ]] ||
            die "当前内核 $kind 软件包状态异常，不清理其他内核。"
    done
    for driver in tcp_bbr_guard sch_fq "${NIC_DRIVERS[@]}"; do
        modinfo -k "$release" "$driver" >/dev/null || die "当前内核缺少驱动 $driver，不清理其他内核。"
    done
    grub-script-check /boot/grub/grub.cfg
    grub_entry_for "$release" >/dev/null
}

refresh_kernel_boot_links() {
    python3 - "$1" <<'PY_BOOT_LINKS'
from pathlib import Path
import os, sys, tempfile
release = sys.argv[1]
for directory in (Path('/boot'), Path('/')):
    for name in ('vmlinuz', 'initrd.img'):
        target = Path('/boot') / (name + '-' + release)
        for suffix in ('', '.old'):
            link = directory / (name + suffix)
            # Only standard aliases are touched; never overwrite a real image.
            if not link.is_symlink() and link.exists():
                raise SystemExit('Boot alias is not a symlink: ' + str(link))
            if link.is_symlink():
                with tempfile.TemporaryDirectory(prefix='.bbr-links-', dir=directory) as temporary:
                    replacement = Path(temporary) / 'link'
                    replacement.symlink_to(os.path.relpath(target, directory))
                    replacement.replace(link)
PY_BOOT_LINKS
}

verify_only_current_kernel() {
    local release=$1 inventory name state file
    inventory=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 'linux-*') || die '无法复核内核软件包清单。'
    while IFS=$'\t' read -r name state; do
        if [[ $state == installed ]] && is_kernel_package "$name" && ! kernel_package_for_release "$name" "$release"; then
            die "仍有其他内核包 $name，清理尚未完成。"
        fi
    done <<< "$inventory"
    for file in /boot/vmlinuz-* /boot/initrd.img-* /lib/modules/*; do
        [[ -e $file || -L $file ]] || continue
        case "$file" in /boot/vmlinuz-"$release"|/boot/initrd.img-"$release"|/lib/modules/"$release") continue ;; esac
        die "仍有其他内核文件 $file；可能不受软件包管理，请检查后重试清理。"
    done
}

cleanup_old_kernels() {
    if (( DRY_RUN )); then
        say '[预览] 检查当前 Guard7、启动文件、网卡、SSH 和路由；仅保留当前 BBR 内核及其 headers，删除其他内核（包括原回退内核）。完成后没有备用内核。'
        return
    fi
    [[ ! -e $STATE/install-pending && ! -L $STATE/install-pending ]] || die '安装事务未完成，禁止清理旧内核；请先重试安装以恢复配置。'
    [[ -f $STATE/kernel-release && ! -L $STATE/kernel-release ]] || die '缺少有效的 BBR 内核安装记录，不能清理。'
    [[ ! -e /var/lib/ubuntu-dd/reinstall-pending ]] || die '存在待执行 DD，暂停旧内核清理。'
    local release routes marker
    release=$(cat "$STATE/kernel-release")
    [[ $release =~ ^[0-9][a-zA-Z0-9.+~-]+$ && $(uname -r) == "$release" ]] || die '尚未成功启动记录的新内核，不删除旧内核。'
    PROFILE=$(cat "$STATE/profile"); select_profile
    modprobe "$BBR_MODULE"
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "$ALGORITHM" ]] || die '新内核算法尚未生效，保留旧内核。'
    detect_nics
    (( ${#NIC_NAMES[@]} )) || die '未识别到网卡，不清理旧内核。'
    local driver
    for driver in "${NIC_DRIVERS[@]}"; do [[ $driver != unknown ]] || die '网卡驱动未知。'; done
    [[ $(modinfo -F version "$BBR_MODULE") == 3-guard7-r2-experimental ]] || die '当前模块不是 Guard7 R2，不清理其他内核。'
    verify_running_kernel_files "$release"
    systemctl is-active --quiet ssh || systemctl is-active --quiet sshd || die 'SSH 服务未就绪，不清理旧内核。'
    routes=$(ip -4 route show default; ip -6 route show default)
    [[ -n $routes ]] || die '没有默认路由，不清理旧内核。'
    for marker in cleanup-pending cleanup-incomplete; do
        [[ ! -L $STATE/$marker && ( ! -e $STATE/$marker || -f $STATE/$marker ) ]] || die '清理任务标记异常。'
    done
    touch "$STATE/cleanup-pending" "$STATE/cleanup-incomplete"
    # Pin the running kernel before APT hooks can regenerate GRUB. Failures
    # retain the markers so manual cleanup can resume without a rollback kernel.
    set_new_boot_default "$release"
    purge_old_kernel_packages "$release"
    refresh_kernel_boot_links "$release"
    set_new_boot_default "$release"
    verify_running_kernel_files "$release"
    verify_only_current_kernel "$release"
    systemctl disable --now bbr-kernel-cleanup.timer
    rm -f -- "$STATE/rollback-release" "$STATE/cleanup-pending" "$STATE/cleanup-incomplete"
    say "清理完成，仅保留当前 BBR 内核 $release 及其 headers；其他内核和原回退记录已移除。"
}

# BEGIN MENU HELPERS
menu_line() {
    local style=$1 color
    shift
    case "$style" in
        title) color='1;37' ;; install) color='1;32' ;; info) color='1;36' ;;
        recovery) color='1;33' ;; danger) color='1;31' ;; test) color='1;35' ;;
        exit) color='90' ;; *) color='0' ;;
    esac
    if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        printf '\033[%sm%s\033[0m\n' "$color" "$*"
    else
        printf '%s\n' "$*"
    fi
}

menu_exit() {
    if [[ ${MENU_WORKER:-0} == 1 ]]; then exit 200; fi
    exit 0
}

require_menu_terminal() {
    [[ -t 0 && -t 1 ]] || die '请在交互终端直接运行脚本，使用中文数字菜单。'
}

menu_choice() {
    local allowed=" $* "
    while true; do
        read -r -p '请输入选项数字（0 退出）：' REPLY || menu_exit
        [[ $REPLY != 0 ]] || menu_exit
        if [[ $REPLY =~ ^[1-9][0-9]*$ && $allowed == *" $REPLY "* ]]; then return 0; fi
        say '选项无效，请重新输入菜单中的数字。'
    done
}

menu_cloud() {
    menu_line title '选择云平台：'
    menu_line info '1、自动识别（推荐）'
    menu_line info '2、谷歌云 GCP'
    menu_line info '3、亚马逊 Lightsail'
    menu_line info '4、亚马逊 AWS EC2'
    menu_line info '5、甲骨文云 OCI'
    menu_line info '6、其他平台'
    menu_line exit '0、退出'
    menu_choice 1 2 3 4 5 6
    case "$REPLY" in
        1) CLOUD=auto ;; 2) CLOUD=gcp ;; 3) CLOUD=lightsail ;;
        4) CLOUD=aws ;; 5) CLOUD=oci ;; 6) CLOUD=generic ;;
    esac
}

run_menu_action() {
    # Do not put the action in an if/|| condition: that disables Bash errexit
    # throughout called functions and can continue installation after failure.
    local result
    if (( $# == 0 )); then set -- dispatch; fi
    set +e
    (
        set -Eeuo pipefail
        MENU_WORKER=1
        trap 'exit 130' INT
        trap 'exit 143' TERM
        trap 'exit 129' HUP
        trap 'printf "操作失败（行 %s，退出码 %s），已停止本次操作；未自动重启。\n" "$LINENO" "$?" >&2' ERR
        "$@"
    )
    result=$?
    set -e
    if (( result == 200 )); then exit 0; fi
    case "$result" in 129|130|143) exit "$result" ;; esac
    if (( result != 0 )); then
        say '请根据上方错误处理后重试。若 DD 已修改引导，先在 DD 菜单取消待执行重装。'
    fi
}

reboot_host() {
    if (( DRY_RUN )); then say '[预览] 重启当前系统。'; return; fi
    say '重启会断开当前 SSH 连接。'
    if [[ ${1:-} == confirm ]]; then
        menu_line danger '1、确认重启当前系统'
        menu_line recovery '2、取消重启，返回主菜单'
        menu_line exit '0、退出'
        menu_choice 1 2
        [[ $REPLY == 1 ]] || return 0
    fi
    systemctl reboot
}
# END MENU HELPERS

# BEGIN NGINX BUILD
# Shared by the explicit source-install path and the local packager.
nginx_build_jobs() {
    python3 - <<'PY_JOBS'
import os
from pathlib import Path
mem = {p[0].rstrip(':'): int(p[1]) for line in Path('/proc/meminfo').read_text().splitlines() if (p := line.split()) and p[0] in ('MemTotal:', 'MemAvailable:')}
available = mem.get('MemAvailable', mem['MemTotal']) * 1024
cpus = len(os.sched_getaffinity(0))
# Walk the current v2 cgroup and its ancestors: nested quotas also apply.
for line in Path('/proc/self/cgroup').read_text().splitlines():
    if line.startswith('0::'):
        current = Path('/sys/fs/cgroup') / line[3:].lstrip('/')
        while current.is_relative_to('/sys/fs/cgroup'):
            try:
                limit = (current / 'memory.max').read_text().strip()
                used = int((current / 'memory.current').read_text())
                if limit != 'max': available = min(available, max(0, int(limit) - used))
                quota, period = (current / 'cpu.max').read_text().split()
                if quota != 'max': cpus = min(cpus, max(1, int(quota) // int(period)))
            except (OSError, ValueError): pass
            current = current.parent
print(max(1, min(cpus, (available - 256 * 1024**2) // (512 * 1024**2))))
PY_JOBS
}

nginx_compile_stage() (
    local work=$1 stage=$2 jobs=$3 openssl_version=$4
    # A caller's shell flags must not silently change a cached/native payload.
    export CC=gcc CXX=g++
    unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS MAKEFLAGS MFLAGS
    cmake -S "$work/brotli/deps/brotli" -B "$work/brotli/deps/brotli/out" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBROTLI_DISABLE_TESTS=ON
    cmake --build "$work/brotli/deps/brotli/out" --target brotlienc brotlicommon --parallel "$jobs"
    cd "$work/nginx-$NGX_VERSION"
    ./configure --build=local-quic-brotli --prefix=/usr/local/nginx --sbin-path=/usr/sbin/nginx \
        --modules-path=/usr/local/nginx/modules --conf-path=/etc/nginx/nginx.conf \
        --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
        --pid-path=/run/nginx.pid --lock-path=/run/nginx.lock --user=nginx --group=nginx \
        --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
        --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
        --http-scgi-temp-path=/var/cache/nginx/scgi_temp --with-file-aio --with-threads --with-compat --with-pcre-jit \
        --with-http_ssl_module --with-http_v2_module --with-http_v3_module --with-http_realip_module \
        --with-http_gunzip_module --with-http_gzip_static_module --with-http_auth_request_module \
        --with-http_slice_module --with-http_stub_status_module --with-stream --with-stream_ssl_module \
        --with-stream_realip_module --with-stream_ssl_preread_module \
        --add-dynamic-module="$work/geoip2" --add-dynamic-module="$work/brotli" \
        --with-openssl="$work/openssl-$openssl_version" --with-openssl-opt='enable-ktls no-shared no-tests no-apps' \
        --with-cc-opt='-O2 -pipe -fPIC -fstack-protector-strong -D_FORTIFY_SOURCE=2' \
        --with-ld-opt='-Wl,-O1 -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -ldl -lpthread -lstdc++'
    make -j"$jobs"
    make install DESTDIR="$stage"
    strip --strip-unneeded "$stage/usr/sbin/nginx" "$stage"/usr/local/nginx/modules/*.so
    "$stage/usr/sbin/nginx" -V
)

nginx_build_stage() {
    local work=$1 cache=$2 stage=$3 jobs recipe cached started=$SECONDS
    local openssl_version=3.5.7
    local openssl_sha=a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8
    local geoip_commit=445df24ef3781e488cee3dfe8a1e111997fc1dfe
    local brotli_commit=a71f9312c2deb28875acc7bacfdd5695a111aa53
    need gcc; need cmake; need git; need perl; need pkg-config; need strip
    read_os
    NGX_ARCH=$(dpkg --print-architecture)
    [[ $NGX_ARCH == amd64 || $NGX_ARCH == arm64 ]] || die 'Nginx 构建仅支持 amd64 / arm64。'
    [[ ! -L $cache ]] || die 'Nginx 缓存目录不能是符号链接。'
    install -d -m 700 "$cache"
    nginx_source "$work"
    # Include every recipe function, source identity, native toolchain and installed
    # dependency version. Never reuse solely on the upstream version number.
    recipe=$({
        declare -f nginx_compile_stage nginx_build_stage nginx_package_tool
        printf '%s\n' "$ID" "$VERSION_ID" "$NGX_ARCH" "$NGX_VERSION" "$openssl_sha" "$geoip_commit" "$brotli_commit"
        sha256sum "$work/nginx.tar.gz" | cut -d' ' -f1
        gcc -v 2>&1
        ld --version
        cmake --version
        make --version
        dpkg-query -W -f='${binary:Package}=${Version}\n' | LC_ALL=C sort
    } | sha256sum); recipe=${recipe%% *}
    export NGX_RECIPE=$recipe
    cached=$cache/$recipe.tar.gz
    if [[ -f $cached && -f $cached.sha256 && ! -L $cached && ! -L $cached.sha256 ]]; then
        (cd "$cache"; sha256sum -c "$recipe.tar.gz.sha256") || die 'Nginx 构建缓存损坏，请移走对应缓存后重试。'
        nginx_package_tool extract "$cached" "$stage" "$ID" "$VERSION_ID" "$NGX_ARCH" "$recipe" >/dev/null
        say "复用已校验 Nginx 构建缓存；准备耗时 $((SECONDS-started)) 秒。"
        return
    fi
    download_verified "https://github.com/openssl/openssl/releases/download/openssl-$openssl_version/openssl-$openssl_version.tar.gz" \
        "$cache/openssl-$openssl_version.tar.gz" "$openssl_sha" 1
    cp "$cache/openssl-$openssl_version.tar.gz" "$work/openssl.tar.gz"
    tar -xzf "$work/openssl.tar.gz" -C "$work" --no-same-owner
    nginx_module_source https://github.com/leev/ngx_http_geoip2_module.git "$work/geoip2" "$geoip_commit"
    nginx_module_source https://github.com/google/ngx_brotli.git "$work/brotli" "$brotli_commit"
    git -C "$work/brotli" -c protocol.file.allow=never submodule update --init --recursive --depth=1
    # Archive corresponding sources before generating any compiler output.
    tar -czf "$work/sources.tar.gz" --exclude=.git -C "$work" nginx.tar.gz nginx.tar.gz.asc \
        signature.status nginx.sha256 openssl.tar.gz geoip2 brotli
    jobs=$(nginx_build_jobs)
    say "源码准备耗时 $((SECONDS-started)) 秒；使用 $jobs 个编译任务。"
    started=$SECONDS
    nginx_compile_stage "$work" "$stage" "$jobs" "$openssl_version"
    nginx_package_tool seal "$stage" "$ID" "$VERSION_ID" "$NGX_ARCH" "$NGX_VERSION" "$recipe"
    nginx_package_tool pack "$stage" "$cached.part"
    mv -T "$cached.part" "$cached"
    cp "$work/sources.tar.gz" "$cache/$recipe.sources.tar.gz"
    (cd "$cache"; sha256sum "$recipe.tar.gz" "$recipe.sources.tar.gz" > "$recipe.tar.gz.sha256")
    say "编译与暂存耗时 $((SECONDS-started)) 秒；已保存校验缓存。"
}
# END NGINX BUILD

# BEGIN NGINX PACKAGE
nginx_package_tool() {
    python3 -B - "$@" <<'PY_NGINX_PACKAGE'
"""Create and validate the small, platform-specific Nginx payload (no install hooks)."""
import hashlib
import json
from pathlib import Path
import re
import struct
import tarfile

MODULES = ('ngx_http_geoip2_module', 'ngx_stream_geoip2_module',
           'ngx_http_brotli_filter_module', 'ngx_http_brotli_static_module')
FILES = ('usr/sbin/nginx', 'etc/nginx/mime.types',
         *(f'usr/local/nginx/modules/{name}.so' for name in MODULES))
LIMIT = 128 * 1024 * 1024


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def validate_metadata(meta, system, version, arch):
    if (meta.get('format') != 1 or meta.get('system') != system or
            meta.get('system_version') != version or meta.get('architecture') != arch or
            arch not in ('amd64', 'arm64') or
            not re.fullmatch(r'\d+\.\d+\.\d+', meta.get('nginx_version', '')) or
            not re.fullmatch(r'[a-f0-9]{64}', meta.get('recipe', '')) or
            set(meta.get('files', {})) != set(FILES)):
        raise ValueError('Nginx 包平台、格式或文件清单不匹配')
    for info in meta['files'].values():
        if (not isinstance(info, dict) or not isinstance(info.get('size'), int) or
                not 0 < info['size'] <= LIMIT or
                not re.fullmatch(r'[a-f0-9]{64}', info.get('sha256', ''))):
            raise ValueError('Nginx 文件大小或 SHA-256 无效')


def check_elf(path, arch):
    with path.open('rb') as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or
            struct.unpack('<H', header[18:20])[0] != {'amd64': 62, 'arm64': 183}[arch]):
        raise ValueError('Nginx ELF 架构不匹配: ' + str(path))


def verify_tree(stage, system, version, arch):
    stage = Path(stage)
    meta = json.loads((stage / 'nginx-build.json').read_text())
    validate_metadata(meta, system, version, arch)
    for name in FILES:
        path = stage / name
        info = meta['files'][name]
        if path.is_symlink() or not path.is_file() or path.stat().st_size != info['size'] or digest(path) != info['sha256']:
            raise ValueError('Nginx 文件校验失败: ' + name)
        if name != 'etc/nginx/mime.types':
            check_elf(path, arch)
    return meta


def extract_package(archive, destination, system, version, arch, recipe=None):
    archive, destination = Path(archive), Path(destination)
    if archive.is_symlink() or archive.stat().st_size > LIMIT:
        raise ValueError('Nginx 包类型或大小异常')
    # Read only the finite payload; do not use extractall on downloaded archives.
    allowed = set(FILES) | {'nginx-build.json'}
    data = {}
    total = 0
    with tarfile.open(archive, 'r:gz') as bundle:
        for item in bundle:
            total += item.size
            if (item.name not in allowed or item.name in data or not item.isreg() or
                    item.issparse() or not 0 < item.size <= LIMIT or total > LIMIT or
                    (item.name == 'nginx-build.json' and item.size > 65536)):
                raise ValueError('Nginx 压缩包含异常、重复或越界文件')
            data[item.name] = bundle.extractfile(item).read()
            if len(data[item.name]) != item.size:
                raise ValueError('Nginx 压缩包不完整')
    if set(data) != allowed:
        raise ValueError('Nginx 压缩包缺少必需文件')
    meta = json.loads(data['nginx-build.json'])
    validate_metadata(meta, system, version, arch)
    if recipe is not None and meta['recipe'] != recipe:
        raise ValueError('Nginx 缓存与当前构建身份不匹配')
    for name in FILES:
        if (len(data[name]) != meta['files'][name]['size'] or
                hashlib.sha256(data[name]).hexdigest() != meta['files'][name]['sha256']):
            raise ValueError('Nginx 压缩包内部校验失败: ' + name)
    # New staging directory, never overlay existing files or follow links.
    destination.mkdir(mode=0o700)
    for name, content in data.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        path.chmod(0o644 if name in ('nginx-build.json', 'etc/nginx/mime.types') else 0o755)
    verify_tree(destination, system, version, arch)
    return meta


def seal(stage, system, version, arch, nginx_version, recipe):
    stage = Path(stage)
    meta = dict(format=1, system=system, system_version=version, architecture=arch,
                nginx_version=nginx_version, recipe=recipe,
                files={name: dict(size=(stage / name).stat().st_size, sha256=digest(stage / name)) for name in FILES})
    (stage / 'nginx-build.json').write_text(json.dumps(meta, indent=2, sort_keys=True) + '\n')
    verify_tree(stage, system, version, arch)


def package(stage, output):
    with tarfile.open(output, 'w:gz', compresslevel=6) as bundle:
        for name in (*FILES, 'nginx-build.json'):
            bundle.add(Path(stage) / name, arcname=name, recursive=False)


def main():
    import sys
    command, *args = sys.argv[1:]
    if command == 'extract':
        print(extract_package(*args)['nginx_version'])
    elif command == 'verify':
        print(verify_tree(*args)['nginx_version'])
    elif command == 'seal':
        seal(*args)
    elif command == 'pack':
        package(*args)
    else:
        raise ValueError('Unknown Nginx package operation')


if __name__ == '__main__':
    main()
PY_NGINX_PACKAGE
}
# END NGINX PACKAGE

# BEGIN NGINX HELPERS
# Maintained here and embedded in bbr.sh by sync_embedded.py.
nginx_stable_version() {
    python3 - "$1" <<'PY_NGINX_STABLE'
from html.parser import HTMLParser
from pathlib import Path
import re
import sys

class Stable(HTMLParser):
    def __init__(self):
        super().__init__()
        self.heading = None
        self.stable = False
        self.versions = set()
    def handle_starttag(self, tag, attrs):
        if tag == 'h4':
            self.heading = ''
            self.stable = False
        if tag == 'a' and self.stable:
            href = dict(attrs).get('href', '')
            match = re.fullmatch(r'/download/nginx-(\d+\.\d+\.\d+)\.tar\.gz', href)
            if match:
                self.versions.add(match[1])
    def handle_data(self, data):
        if self.heading is not None:
            self.heading += data
    def handle_endtag(self, tag):
        if tag == 'h4':
            self.stable = self.heading.strip() == 'Stable version'
            self.heading = None

page = Stable()
page.feed(Path(sys.argv[1]).read_text())
if not page.versions:
    sys.exit('无法从 Nginx 官网识别稳定版，停止安装。')
print(max(page.versions, key=lambda v: tuple(map(int, v.split('.')))))
PY_NGINX_STABLE
}

nginx_fetch() {
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 20 --speed-limit 1024 --speed-time 120 -o "$2" "$1"
}

nginx_source() {
    local work=$1 key
    nginx_fetch https://nginx.org/en/download.html "$work/download.html"
    NGX_VERSION=$(nginx_stable_version "$work/download.html")
    say "Nginx 官网最新稳定版：$NGX_VERSION"
    nginx_fetch "https://nginx.org/download/nginx-$NGX_VERSION.tar.gz" "$work/nginx.tar.gz"
    nginx_fetch "https://nginx.org/download/nginx-$NGX_VERSION.tar.gz.asc" "$work/nginx.tar.gz.asc"
    install -d -m 700 "$work/gnupg"
    for key in arut pluknet sb thresh; do
        nginx_fetch "https://nginx.org/keys/$key.key" "$work/$key.key"
        gpg --homedir "$work/gnupg" --batch --import "$work/$key.key"
    done
    gpg --homedir "$work/gnupg" --batch --status-fd 1 --verify \
        "$work/nginx.tar.gz.asc" "$work/nginx.tar.gz" > "$work/signature.status"
    # Accept only Nginx's four source-release signing identities, not arbitrary keys.
    grep -Eq '^\[GNUPG:\] VALIDSIG (43387825DDB1BB97EC36BA5D007C8D7C15D87369|D6786CE303D9A9022998DC6CC8464D549AF75C0A|7338973069ED3F443F4D37DFA64FD5B17ADB39A8|13C82A63B603576156E30A4EA0EA981B66B0D967) ' "$work/signature.status" ||
        die 'Nginx 签名者不在已核实的官方发布者列表中。'
    sha256sum "$work/nginx.tar.gz" > "$work/nginx.sha256"
    tar -xzf "$work/nginx.tar.gz" -C "$work" --no-same-owner
}

nginx_module_source() {
    local url=$1 directory=$2 commit=$3
    git init -q "$directory"
    git -C "$directory" -c protocol.file.allow=never fetch --depth=1 "$url" "$commit"
    git -C "$directory" checkout --detach FETCH_HEAD
    [[ $(git -C "$directory" rev-parse HEAD) == "$commit" ]] || die 'Nginx 模块源码提交不匹配。'
}

nginx_recover_swap() (
    # The journal binds recovery to the inode created by this tool. Never infer
    # ownership from the filename of an old, unmarked swap file.
    local directory=$1 pending=$1/swap.pending swap=$1/swapfile marker=$1/swap.uuid
    local identity name uuid extra staged target recovery_active marker_tmp=''
    [[ -e $pending || -L $pending ]] || return 0
    [[ -d $directory && ! -L $directory && -f $pending && ! -L $pending &&
       $(stat -c '%u:%a' "$pending") == 0:600 && ! -L $swap && ! -L $marker ]] ||
        die 'swap 恢复记录或路径异常，未修改。'
    read -r identity name uuid extra < "$pending" || die '无法读取 swap 恢复记录。'
    [[ $identity =~ ^[0-9]+:[0-9]+$ && $name =~ ^\.swapfile\.[a-zA-Z0-9]+$ &&
       $uuid =~ ^[a-zA-Z0-9-]+$ && -z $extra ]] || die 'swap 恢复记录格式异常。'
    staged=$directory/$name
    target=$staged
    [[ ! -e $swap ]] || target=$swap
    if [[ $uuid == - && ! -e $staged && ! -L $staged && ! -e $swap ]]; then
        rm -f -- "$pending" || return 1
        return
    fi
    [[ -f $target && ! -L $target && $(stat -c '%u:%a' "$target") == 0:600 &&
       $(stat -c '%d:%i' "$target") == "$identity" ]] || die 'swap 恢复文件不属于本次创建，未修改。'
    recovery_active=$(swapon --noheadings --raw --show=NAME) || die '无法读取活动 swap，未清理。'
    if [[ $uuid == - ]]; then
        [[ $target == "$staged" && ! -e $marker ]] || die '未完成的 swap 创建状态冲突。'
        ! grep -Fxq "$staged" <<< "$recovery_active" || die '临时 swap 正在使用，未删除。'
        rm -f -- "$staged" "$pending" || return 1
        return
    fi
    [[ $(stat -c '%u:%a:%s' "$target") == 0:600:2147483648 &&
       $(blkid -p -s TYPE -o value "$target") == swap &&
       $(blkid -p -s UUID -o value "$target") == "$uuid" ]] || die '待恢复 swap 校验失败。'
    if [[ $target == "$staged" ]]; then
        ! grep -Fxq "$staged" <<< "$recovery_active" || die '临时 swap 正在使用，未移动。'
        mv -T -- "$staged" "$swap" || return 1
    fi
    if [[ -e $marker ]]; then
        [[ -f $marker && $(cat "$marker") == "$uuid" ]] || die 'swap 标识冲突，未覆盖。'
    else
        marker_tmp=$(mktemp "$directory/.swap-uuid.XXXXXX") || return 1
        trap 'rm -f -- "$marker_tmp"' EXIT
        printf '%s\n' "$uuid" > "$marker_tmp" || return 1
        mv -T -- "$marker_tmp" "$marker" || return 1
    fi
    rm -f -- "$pending" || return 1
)

nginx_prepare_swap() (
    local directory=$1 fstab=${2:-/etc/fstab} swap marker uuid pending identity active
    local swap_tmp='' journal_tmp='' fstab_tmp=''
    swap=$directory/swapfile; marker=$directory/swap.uuid
    pending=$directory/swap.pending
    [[ -d $directory && ! -L $directory && ! -L $swap && ! -L $marker &&
       -f $fstab && ! -L $fstab ]] || die 'swap 或 fstab 路径异常，未覆盖。'
    trap '
        result=$?
        trap - EXIT
        if (( result != 0 )); then nginx_recover_swap "$directory" || true; fi
        if [[ -n $swap_tmp && ! -e $pending ]]; then
            if active=$(swapon --noheadings --raw --show=NAME) && ! grep -Fxq "$swap_tmp" <<< "$active"; then
                rm -f -- "$swap_tmp"
            fi
        fi
        rm -f -- "$journal_tmp" "$fstab_tmp"
        exit "$result"
    ' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    nginx_recover_swap "$directory"
    if [[ ! -e $swap ]]; then
        [[ ! -e $marker ]] || die 'swap 文件缺失但标识仍在，请检查后重试。'
        say '创建永久 2 GiB swap；安装完成后保留，重启自动启用。'
        swap_tmp=$(mktemp "$directory/.swapfile.XXXXXX")
        identity=$(stat -c '%d:%i' "$swap_tmp")
        journal_tmp=$(mktemp "$directory/.swap-journal.XXXXXX")
        printf '%s %s -\n' "$identity" "${swap_tmp##*/}" > "$journal_tmp"
        mv -T -- "$journal_tmp" "$pending"
        dd if=/dev/zero of="$swap_tmp" bs=1M count=2048 status=progress
        mkswap "$swap_tmp"
        uuid=$(blkid -p -s UUID -o value "$swap_tmp")
        [[ -n $uuid ]] || die '无法读取新 swap 标识。'
        journal_tmp=$(mktemp "$directory/.swap-journal.XXXXXX")
        printf '%s %s %s\n' "$identity" "${swap_tmp##*/}" "$uuid" > "$journal_tmp"
        mv -T -- "$journal_tmp" "$pending"
        nginx_recover_swap "$directory"
        swap_tmp=''
    fi
    if [[ -e $swap ]]; then
        [[ -f $swap && -f $marker && $(stat -c '%u:%a:%s' "$swap") == 0:600:2147483648 ]] ||
            die '专用 swap 路径已有其他文件，未覆盖。'
        uuid=$(blkid -p -s UUID -o value "$swap")
        [[ $(blkid -p -s TYPE -o value "$swap") == swap && $uuid == "$(cat "$marker")" ]] ||
            die '专用 swap 标识不匹配，未覆盖。'
    fi
    # Refuse conflicting entries rather than silently modifying existing policy.
    awk -v p="$swap" '$1 == p { n++; if ($2 != "none" || $3 != "swap" || $4 != "sw,nofail" || $5 != "0" || $6 != "0") bad=1 } END { exit (bad || n > 1) }' "$fstab" ||
        die 'fstab 中专用 swap 配置冲突，请检查后重试。'
    active=$(swapon --noheadings --raw --show=NAME) || die '无法读取活动 swap。'
    if ! grep -Fxq "$swap" <<< "$active"; then swapon "$swap"; fi
    if ! awk -v p="$swap" '$1 == p { found=1 } END { exit !found }' "$fstab"; then
        cp -a -- "$fstab" "$directory/fstab.before-swap"
        fstab_tmp=$(mktemp "${fstab}.bbr-nginx.XXXXXX")
        cp -p -- "$fstab" "$fstab_tmp"
        printf '\n%s none swap sw,nofail 0 0 # bbr-nginx\n' "$swap" >> "$fstab_tmp"
        mv -T -- "$fstab_tmp" "$fstab"
        fstab_tmp=''
    fi
    systemctl daemon-reload
    say "永久 2 GiB swap 已启用：$swap（重复安装复用，保留其他 swap）。"
)

nginx_default_config() {
    cat <<'NGINX_CONF'
load_module /usr/local/nginx/modules/ngx_http_geoip2_module.so;
load_module /usr/local/nginx/modules/ngx_http_brotli_filter_module.so;
load_module /usr/local/nginx/modules/ngx_http_brotli_static_module.so;
user nginx;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;
events { worker_connections 4096; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /var/log/nginx/access.log;
    sendfile on;
    keepalive_timeout 65;
    gzip on;
    brotli on;
    brotli_comp_level 4;
    brotli_types text/plain text/css application/javascript application/json image/svg+xml;
    server {
        listen 80 default_server;
        server_name _;
        location / {
            default_type text/plain;
            return 200 "Nginx is running.\n";
        }
    }
    include /etc/nginx/conf.d/*.conf;
}
NGINX_CONF
}

nginx_service() {
    cat <<'NGINX_SERVICE'
[Unit]
Description=Nginx HTTP and reverse proxy server
After=network-online.target
Wants=network-online.target
[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t
ExecStart=/usr/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/sbin/nginx -t
ExecReload=/bin/kill -HUP $MAINPID
ExecStop=/bin/kill -QUIT $MAINPID
Restart=on-failure
RestartSec=3
LimitNOFILE=300000
TimeoutStartSec=30
TimeoutStopSec=30
KillMode=mixed
PrivateTmp=true
[Install]
WantedBy=multi-user.target
NGINX_SERVICE
}

nginx_restore_install() {
    local backup=$1 path
    systemctl stop nginx || true
    while IFS= read -r path; do
        rm -rf -- "$path"
    done < <(nginx_install_paths)
    tar -xpf "$backup/original.tar" -C / || return 1
    systemctl daemon-reload || return 1
    if [[ $NGX_WAS_ENABLED == enabled ]]; then systemctl enable nginx || return 1
    else systemctl disable nginx 2>/dev/null || true; fi
    if (( NGX_WAS_ACTIVE )); then systemctl start nginx || return 1; fi
}

nginx_finish() {
    local result=$1
    trap - EXIT
    if (( result != 0 && NGX_CHANGED )); then
        say "安装失败，恢复原 Nginx；备份：$NGX_BACKUP"
        nginx_restore_install "$NGX_BACKUP" || say "自动恢复未完成，请保留备份 $NGX_BACKUP 并检查 nginx 服务。"
    fi
    rm -rf -- "$NGX_WORK"
    exit "$result"
}

nginx_prebuilt_platform() {
    read_os
    NGX_ARCH=$(dpkg --print-architecture)
    [[ $ID == ubuntu && $VERSION_ID == 24.04 && $NGX_ARCH == amd64 && $(uname -m) == x86_64 ]] ||
        die '当前 Nginx 预编译包仅支持 Ubuntu 24.04 amd64；其他平台请在“安装 Nginx”中选择源码编译。'
    NGX_ASSET=nginx-ubuntu-${VERSION_ID}-${NGX_ARCH}.tar.gz
}

nginx_download_package() {
    local work=$1 expected actual url manifest=$1/NGINX_SHA256SUMS
    if [[ -n ${NGINX_PACKAGE_DIR:-} ]]; then
        [[ $NGINX_PACKAGE_DIR == /* && -d $NGINX_PACKAGE_DIR && ! -L $NGINX_PACKAGE_DIR &&
           -f $NGINX_PACKAGE_DIR/NGINX_SHA256SUMS && ! -L $NGINX_PACKAGE_DIR/NGINX_SHA256SUMS &&
           -f $NGINX_PACKAGE_DIR/$NGX_ASSET && ! -L $NGINX_PACKAGE_DIR/$NGX_ASSET ]] || die '本地 Nginx 包目录不完整或路径异常。'
        cp "$NGINX_PACKAGE_DIR/NGINX_SHA256SUMS" "$manifest"
        expected=$(release_checksum "$manifest" "$NGX_ASSET") || die 'Nginx 清单缺少唯一有效的包 SHA-256。'
        cp "$NGINX_PACKAGE_DIR/$NGX_ASSET" "$work/$NGX_ASSET"
    else
        [[ $TOOL_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '项目版本格式异常。'
        url=https://github.com/lookfeeb/ubuntu-bbr-dd/releases/download/v$TOOL_VERSION
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 60 --max-filesize 1048576 --retry 2 \
            --output "$manifest" "$url/NGINX_SHA256SUMS" || die '此 Release 的 Nginx 预编译包尚不可用；可在“安装 Nginx”中选择源码编译。'
        expected=$(release_checksum "$manifest" "$NGX_ASSET") || die 'Nginx 清单缺少唯一有效的包 SHA-256。'
        download_verified "$url/$NGX_ASSET" "$work/$NGX_ASSET" "$expected" 1
    fi
    actual=$(sha256sum "$work/$NGX_ASSET"); actual=${actual%% *}
    [[ $actual == "$expected" ]] || die 'Nginx 包 SHA-256 不匹配，未安装。'
    NGX_VERSION=$(nginx_package_tool extract "$work/$NGX_ASSET" "$work/stage" "$ID" "$VERSION_ID" "$NGX_ARCH")
}

nginx_install_paths() {
    printf '%s\n' /etc/nginx /usr/sbin/nginx /usr/local/nginx /etc/systemd/system/nginx.service \
        /usr/share/GeoIP/GeoLite2-City.mmdb /var/lib/bbr-nginx/installed.json
}

nginx_install_stage() {
    local stage=$1 path
    nginx_package_tool verify "$stage" "$ID" "$VERSION_ID" "$NGX_ARCH" >/dev/null
    "$stage/usr/sbin/nginx" -V
    # Only fetch the database when absent. Reinstallation must not download a
    # replacement that the preserved installation will never use.
    if [[ -e /usr/share/GeoIP/GeoLite2-City.mmdb ]]; then
        mmdblookup --file /usr/share/GeoIP/GeoLite2-City.mmdb --ip 1.1.1.1 >/dev/null
    else
        nginx_fetch https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-City.mmdb "$NGX_WORK/GeoLite2-City.mmdb"
        mmdblookup --file "$NGX_WORK/GeoLite2-City.mmdb" --ip 1.1.1.1 >/dev/null
    fi
    local -a originals=()
    while IFS= read -r path; do
        [[ ! -e $path ]] || originals+=("${path#/}")
    done < <(nginx_install_paths)
    tar -cpf "$NGX_BACKUP/original.tar" -C / --files-from /dev/null "${originals[@]}"
    cp "$stage/nginx-build.json" "$NGX_BACKUP/new-build.json"
    systemctl is-active --quiet nginx && NGX_WAS_ACTIVE=1
    NGX_WAS_ENABLED=$(systemctl is-enabled nginx 2>/dev/null) || true
    id nginx >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin nginx
    NGX_CHANGED=1
    if (( NGX_WAS_ACTIVE )); then systemctl stop nginx; fi
    install -d -m 755 /etc/nginx/conf.d /usr/local/nginx/modules /var/log/nginx /usr/share/GeoIP
    install -d -o nginx -g nginx -m 755 /var/cache/nginx/{client,proxy,fastcgi,uwsgi,scgi}_temp
    install -m 755 "$stage/usr/sbin/nginx" /usr/sbin/nginx
    install -m 755 "$stage"/usr/local/nginx/modules/*.so /usr/local/nginx/modules/
    if [[ ! -e /etc/nginx/nginx.conf ]]; then
        install -m 644 "$stage/etc/nginx/mime.types" /etc/nginx/mime.types
        nginx_default_config > /etc/nginx/nginx.conf
        chmod 644 /etc/nginx/nginx.conf
    fi
    if [[ ! -e /usr/share/GeoIP/GeoLite2-City.mmdb ]]; then
        install -m 644 "$NGX_WORK/GeoLite2-City.mmdb" /usr/share/GeoIP/GeoLite2-City.mmdb
    fi
    nginx_service > /etc/systemd/system/nginx.service
    chmod 644 /etc/systemd/system/nginx.service
    /usr/sbin/nginx -t
    systemctl daemon-reload
    systemctl enable nginx
    systemctl start nginx
    systemctl is-active --quiet nginx
    install -m 644 "$stage/nginx-build.json" /var/lib/bbr-nginx/installed.json
    NGX_CHANGED=0
    say "Nginx $NGX_VERSION 安装完成，已启动并设置开机启动。备份与日志：$NGX_BACKUP"
    say '已包含 HTTP/2、HTTP/3、Brotli、GeoIP2 和 stream；HTTPS / HTTP/3 需配置域名、证书及放行端口。'
}

install_nginx() (
    local mode=${1:-prebuilt} path free_kb
    [[ $mode == prebuilt || $mode == source ]] || die '未知 Nginx 安装方式。'
    if (( DRY_RUN )); then
        if [[ $mode == prebuilt ]]; then
            say '[预览] 下载本项目匹配 Ubuntu 24.04 amd64 的 Nginx 预编译包，校验后安装。'
            say '[预览] 仅安装运行依赖，不创建 swap；保留站点配置，失败尝试恢复原安装。'
        else
            say '[预览] 从 nginx.org 识别最新稳定版并验签；复用有效缓存或本机编译。'
            say '[预览] 自动添加永久 2 GiB swap，保留现有站点配置。'
        fi
        return
    fi
    need apt-get; need systemctl
    [[ -d /run/systemd/system ]] || die 'Nginx 自动服务需要 systemd。'
    [[ ! -e /var/lib/ubuntu-dd/reinstall-pending ]] || die '已有 DD 重装计划，请先取消。'
    if [[ $mode == prebuilt ]]; then need python3; nginx_prebuilt_platform; fi
    for path in /var/lib/bbr-nginx /etc/nginx /usr/sbin/nginx /usr/local/nginx /etc/systemd/system/nginx.service \
        /usr/share/GeoIP /usr/share/GeoIP/GeoLite2-City.mmdb /var/lib/bbr-nginx/installed.json; do
        [[ ! -L $path ]] || die "安装目标为符号链接，请先检查：$path"
    done
    install -d -m 700 /var/lib/bbr-nginx
    free_kb=$(df -Pk /var/lib/bbr-nginx | awk 'END {print $4}')
    (( free_kb >= 512 * 1024 )) || die 'Nginx 安装至少需要 512 MiB 可用磁盘空间。'
    NGX_WORK=$(mktemp -d /var/lib/bbr-nginx/build.XXXXXX)
    NGX_BACKUP=$(mktemp -d /var/lib/bbr-nginx/backup.XXXXXX)
    NGX_CHANGED=0; NGX_WAS_ACTIVE=0; NGX_WAS_ENABLED=disabled
    trap 'nginx_finish "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    exec > >(tee -a "$NGX_BACKUP/install.log") 2>&1
    export DEBIAN_FRONTEND=noninteractive
    if [[ $mode == prebuilt ]]; then
        nginx_download_package "$NGX_WORK"
        # Package/hash/platform validation happens before any APT or live changes.
        apt-get update
        apt-get install -y --no-install-recommends --no-remove libcrypt1 libpcre2-8-0 zlib1g libmaxminddb0 mmdb-bin
    else
        nginx_recover_swap /var/lib/bbr-nginx
        free_kb=$(df -Pk /var/lib/bbr-nginx | awk 'END {print $4}')
        (( free_kb >= 8 * 1024 * 1024 )) || die 'Nginx 构建与永久 swap 至少需要 8 GiB 可用磁盘空间。'
        nginx_prepare_swap /var/lib/bbr-nginx
        apt-get update
        apt-get install -y --no-install-recommends --no-remove build-essential cmake git curl ca-certificates perl pkg-config python3 gnupg \
            libpcre2-dev zlib1g-dev libmaxminddb-dev mmdb-bin
        nginx_build_stage "$NGX_WORK" /var/lib/bbr-nginx/cache "$NGX_WORK/stage"
    fi
    nginx_install_stage "$NGX_WORK/stage"
)
# END NGINX HELPERS

# BEGIN APP PAYLOAD
app_payload() {
    python3 -B - "$@" <<'PY_APP_PAYLOAD'
"""Validate official application archives and handle private installation records."""
import ipaddress
import http.cookiejar
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import socket
import sqlite3
import ssl
import struct
import sys
import tarfile
import urllib.parse
import urllib.request


def write_json(path, value):
    path = Path(path)
    with path.open('x', encoding='utf-8') as stream:
        os.chmod(path, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def select_release(app, arch, release):
    repo = {'x-ui': 'MHSanaei/3x-ui', 'openlist': 'OpenListTeam/OpenList'}[app]
    if arch not in ('amd64', 'arm64'):
        raise ValueError('应用发布包架构不受支持')
    if not isinstance(release, dict):
        raise ValueError('官方 Release 元数据格式异常')
    tag = release.get('tag_name', '')
    if (release.get('draft') is not False or release.get('prerelease') is not False or
            not isinstance(tag, str) or not re.fullmatch(r'v?\d+\.\d+\.\d+(?:\.\d+)?', tag, flags=re.ASCII) or
            release.get('html_url') != f'https://github.com/{repo}/releases/tag/{tag}'):
        raise ValueError('官方最新 Release 不是有效稳定版，未安装')
    name = f'{app}-linux-{arch}.tar.gz'
    assets = release.get('assets')
    if not isinstance(assets, list) or not all(isinstance(asset, dict) for asset in assets):
        raise ValueError('官方 Release 资产清单异常')
    matching = [asset for asset in assets if asset.get('name') == name]
    if len(matching) != 1:
        raise ValueError('官方最新稳定版缺少唯一匹配的架构发布包：' + name)
    asset = matching[0]
    digest = asset.get('digest')
    url = f'https://github.com/{repo}/releases/download/{tag}/{name}'
    if (asset.get('state') != 'uploaded' or asset.get('browser_download_url') != url or
            type(asset.get('size')) is not int or not 0 < asset['size'] <= 1024**3 or
            not isinstance(digest, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', digest)):
        raise ValueError('官方发布包的上传状态、下载来源、大小或 SHA-256 异常，未安装')
    return dict(repo=repo, version=tag, name=name, url=url, size=asset['size'], sha256=digest[7:])


def resolve_release(app, arch, filename, destination):
    if Path(filename).stat().st_size > 2097152:
        raise ValueError('官方 Release 元数据过大')
    write_json(destination, select_release(app, arch, json.loads(Path(filename).read_text())))


def extract(app, archive, destination, arch):
    destination = Path(destination)
    destination.mkdir(mode=0o700)
    seen, total = set(), 0
    with tarfile.open(archive, 'r:gz') as bundle:
        for item in bundle:
            name = item.name.removeprefix('./').rstrip('/')
            path = PurePosixPath(name)
            if not name and item.isdir():
                continue
            total += item.size
            if (path.is_absolute() or '..' in path.parts or '\\' in name or
                    any(ord(c) < 32 for c in name) or name in seen or
                    len(seen) >= 2000 or total > 1024**3 or item.size < 0 or
                    item.issparse() or not (item.isdir() or item.isreg()) or
                    (app == 'x-ui' and path.parts[0] != 'x-ui')):
                raise ValueError('发布包包含异常路径、链接、重复文件或超大内容')
            seen.add(name)
            target = destination / path
            if item.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o755 if item.mode & 0o111 else 0o644)
    required = ['openlist'] if app == 'openlist' else ['x-ui/x-ui', f'x-ui/bin/xray-linux-{arch}']
    for name in required:
        path = destination / name
        with path.open('rb') as stream:
            header = stream.read(20)
        if (len(header) != 20 or header[:6] != b'\x7fELF\x02\x01' or
                struct.unpack('<H', header[18:20])[0] != {'amd64': 62, 'arm64': 183}[arch]):
            raise ValueError('发布包缺少正确架构的可执行文件：' + name)
        path.chmod(0o755)


def free_port(preferred):
    for port in [int(preferred)] + [secrets.randbelow(40000) + 20000 for _ in range(64)]:
        sockets = []
        try:
            for family, address in [(socket.AF_INET, '0.0.0.0'), (socket.AF_INET6, '::')]:
                if family == socket.AF_INET6 and not socket.has_ipv6:
                    continue
                sock = socket.socket(family)
                sockets.append(sock)
                if family == socket.AF_INET6:
                    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                try:
                    sock.bind((address, port))
                except OSError as error:
                    if family == socket.AF_INET6 and error.errno == 99:
                        continue
                    raise
            return port
        except OSError:
            continue
        finally:
            for sock in sockets:
                sock.close()
    raise ValueError('找不到可用的管理端口')


def record(app, filename, version, directory, data, port, release_file=None):
    state = dict(format=1, app=app, version=version, directory=directory,
                 data=data, port=int(port), username='admin', password=secrets.token_urlsafe(24),
                 base='/' + secrets.token_hex(12) + '/' if app == 'x-ui' else '/')
    if release_file is not None:
        state['release'] = json.loads(Path(release_file).read_text())
        if state['release']['version'] != version:
            raise ValueError('安装版本与冻结的 Release 信息不一致')
    write_json(filename, state)


def openlist_config(filename):
    state = json.loads(Path(filename).read_text())
    data = Path(state['data'])
    write_json(data / 'config.json', dict(force=True,
               database=dict(type='sqlite3', db_file=str(data / 'data.db'), table_prefix='x_'),
               scheme=dict(address='', http_port=-1, https_port=state['port'],
                           force_https=True, cert_file=str(data / 'tls/cert.pem'),
                           key_file=str(data / 'tls/key.pem'))))


def x_ui_config(filename):
    state = json.loads(Path(filename).read_text())
    # Only invoked for a fresh database before the first service start. Leave
    # subscriptions disabled until the user chooses their inbound/port settings.
    with sqlite3.connect(str(Path(state['data']) / 'x-ui.db')) as db:
        db.execute('delete from settings where key = ?', ('subEnable',))
        db.execute('insert into settings(key, value) values (?, ?)', ('subEnable', 'false'))


def current_state(filename):
    state = json.loads(Path(filename).read_text())
    data = Path(state['data'])
    if state['app'] == 'x-ui':
        with sqlite3.connect((data / 'x-ui.db').as_uri() + '?mode=ro', uri=True) as db:
            settings = dict(db.execute('select key, value from settings'))
            username = db.execute('select username from users order by id limit 1').fetchone()
        state.update(port=int(settings['webPort']), base=settings['webBasePath'],
                     username=username[0], cert=settings['webCertFile'])
    else:
        config = json.loads((data / 'config.json').read_text())
        with sqlite3.connect((data / 'data.db').as_uri() + '?mode=ro', uri=True) as db:
            username = db.execute('select username from x_users where role=2 order by id limit 1').fetchone()
        state.update(port=config['scheme']['https_port'], base='/', username=username[0],
                     cert=config['scheme']['cert_file'])
    if (not 1 <= state['port'] <= 65535 or not state['base'].startswith('/') or
            any(ord(c) < 32 for c in state['base'] + state['username'])):
        raise ValueError('当前应用的管理配置异常')
    return state


def authenticate(state):
    # Trust the installed self-signed certificate, never disable TLS verification.
    context = ssl.create_default_context(cafile=state['cert'])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                        urllib.request.HTTPSHandler(context=context),
                                        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
    base = f'https://127.0.0.1:{state["port"]}' + state['base']
    credentials = dict(username=state['username'], password=state['password'])
    if state['app'] == 'x-ui':
        with opener.open(base + 'csrf-token', timeout=5) as response:
            csrf = json.loads(response.read(65536))
        if csrf.get('success') is not True or not isinstance(csrf.get('obj'), str):
            raise ValueError('无法获取 3X-UI 登录会话')
        request = urllib.request.Request(base + 'login', urllib.parse.urlencode(credentials).encode(),
                                         {'X-CSRF-Token': csrf['obj'], 'X-Requested-With': 'XMLHttpRequest'})
    else:
        request = urllib.request.Request(base + 'api/auth/login', json.dumps(credentials).encode(),
                                         {'Content-Type': 'application/json'})
    with opener.open(request, timeout=5) as response:
        result = json.loads(response.read(1024 * 1024))
    if (result.get('success') is not True if state['app'] == 'x-ui' else result.get('code') != 200):
        raise ValueError('保存的初始凭据未通过登录验证（可能已经修改）')


def addresses():
    result = []
    # Public egress detection is informational; cloud firewalls/NAT are not changed.
    for url in ['https://api.ipify.org', 'https://api6.ipify.org']:
        try:
            with urllib.request.urlopen(url, timeout=3) as response:
                address = str(ipaddress.ip_address(response.read(128).decode().strip()))
            if address not in result:
                result.append(address)
        except (OSError, ValueError):
            pass
    connection = os.environ.get('SSH_CONNECTION', '').split()
    if len(connection) == 4:
        try:
            address = str(ipaddress.ip_address(connection[2]))
            if address not in result:
                result.append(address)
        except ValueError:
            pass
    return result


def report(filename):
    state = current_state(filename)
    print('\n===== ' + ('3X-UI' if state['app'] == 'x-ui' else 'OpenList') + ' 安装与登录信息 =====')
    print('安装版本：' + state['version'])
    print('管理端口：' + str(state['port']) + ' / TCP（HTTPS）')
    for host in addresses() or ['服务器公网 IP']:
        host = '[' + host + ']' if ':' in host else host
        print(f'访问地址：https://{host}:{state["port"]}{state["base"]}')
    print('用户名：' + state['username'])
    try:
        authenticate(state)
        print('密码：' + state['password'])
        print('本机 HTTPS 与登录验证：通过')
    except (OSError, ValueError):
        print('密码：未显示；保存的初始密码未通过当前登录验证，请使用已修改的密码或检查服务。')
    print('凭据记录：' + str(filename) + '（仅 root 可读；修改密码后旧记录不会自动更新）')
    print('数据目录：' + state['data'])
    print('服务状态：systemctl status ' + state['app'])
    print('启动命令：systemctl start ' + state['app'])
    print('停止命令：systemctl stop ' + state['app'])
    print('重启命令：systemctl restart ' + state['app'])
    print('日志命令：journalctl -u ' + state['app'] + ' -n 80 --no-pager')
    print('TLS 证书：' + state['cert'])
    print('使用自动生成的自签证书，浏览器会提示证书不受信任；可在应用配置中更换正式证书。')
    print('公网连通性未验证；请在云安全组/防火墙放行上述 TCP 端口，NAT 主机还需端口映射。')
    if state['app'] == 'x-ui':
        print('代理入站与订阅请登录面板后配置；入站端口需要另行放行。')
    else:
        print('网盘/存储请登录后台添加；WebDAV 路径为 /dav。')


def main():
    command, *args = sys.argv[1:]
    if command == 'extract':
        extract(*args)
    elif command == 'release':
        resolve_release(*args)
    elif command == 'port':
        print(free_port(*args))
    elif command == 'record':
        record(*args)
    elif command == 'field':
        print(json.loads(Path(args[0]).read_text())[args[1]])
    elif command == 'openlist-config':
        openlist_config(*args)
    elif command == 'x-ui-config':
        x_ui_config(*args)
    elif command == 'verify':
        authenticate(current_state(*args))
    elif command == 'report':
        report(*args)
    else:
        raise ValueError('未知应用操作')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('应用处理失败：' + str(error), file=sys.stderr)
        sys.exit(1)
PY_APP_PAYLOAD
}
# END APP PAYLOAD

# BEGIN APP HELPERS
APP_STATE=/var/lib/bbr-apps

app_paths() {
    APP_NAME=$1
    APP_RECORD=$APP_STATE/$APP_NAME.json
    APP_UNIT=/etc/systemd/system/$APP_NAME.service
    case "$APP_NAME" in
        x-ui) APP_DIR=/usr/local/x-ui; APP_DATA=/etc/x-ui; APP_REPO=MHSanaei/3x-ui; APP_PORT=2053 ;;
        openlist) APP_DIR=/opt/openlist; APP_DATA=/opt/openlist/data; APP_REPO=OpenListTeam/OpenList; APP_PORT=5244 ;;
        *) die '未知应用。' ;;
    esac
}

app_architecture() {
    APP_ARCH=$(dpkg --print-architecture)
    case "$APP_ARCH:$(uname -m)" in amd64:x86_64|arm64:aarch64) ;; *) die '应用安装仅支持 amd64 / arm64。' ;; esac
}

app_asset() {
    # Resolve latest once. All subsequent downloads use this exact release and digest.
    say "正在查询 $APP_REPO 官方最新稳定版。"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 10 --max-time 30 --max-filesize 2097152 --retry 2 \
        -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        -A 'ubuntu-bbr-dd' --output "$APP_WORK/release.json" \
        "https://api.github.com/repos/$APP_REPO/releases/latest" || die '查询官方最新稳定版失败，请稍后重试；未使用旧版或未校验的下载包。'
    app_payload release "$APP_NAME" "$APP_ARCH" "$APP_WORK/release.json" "$APP_WORK/selected-release.json"
    APP_VERSION=$(app_payload field "$APP_WORK/selected-release.json" version)
    APP_SHA=$(app_payload field "$APP_WORK/selected-release.json" sha256)
    APP_URL=$(app_payload field "$APP_WORK/selected-release.json" url)
}

app_check_new() {
    local path loaded
    for path in "$APP_DIR" "$APP_DATA" "$APP_UNIT" "$APP_RECORD"; do
        [[ ! -e $path && ! -L $path ]] || die "检测到已有文件 $path；保留原安装与数据，不覆盖或重置密码。"
    done
    if [[ $APP_NAME == x-ui ]]; then
        for path in /usr/bin/x-ui /usr/local/bin/x-ui /etc/default/x-ui /etc/conf.d/x-ui /etc/sysconfig/x-ui; do
            [[ ! -e $path && ! -L $path ]] || die "检测到其他 3X-UI 安装或配置 $path，未修改。"
        done
    fi
    loaded=$(systemctl show "$APP_NAME.service" --property=LoadState --value) || die '无法核对已有 systemd 服务。'
    [[ $loaded == not-found ]] || die "已有 $APP_NAME 服务，未覆盖。"
}

app_cleanup() {
    local result=$?
    trap - EXIT INT TERM HUP
    set +e
    if (( ! APP_COMPLETE )); then
        cat "$APP_WORK/initialize.log" "$APP_WORK/verify.log" 2>/dev/null > "$APP_STATE/$APP_NAME-last-error.log"
        chmod 600 "$APP_STATE/$APP_NAME-last-error.log"
        if (( APP_UNIT_CREATED )); then
            systemctl disable --now "$APP_NAME.service" >/dev/null 2>&1
            rm -f -- "$APP_UNIT"
            systemctl daemon-reload
        fi
        (( ! APP_DATA_CREATED )) || rm -rf -- "$APP_DATA"
        (( ! APP_DIR_CREATED )) || rm -rf -- "$APP_DIR"
        (( ! APP_RECORD_CREATED )) || rm -f -- "$APP_RECORD"
        say '本次应用安装未完成，已撤回本次新增的服务和文件；已安装的系统依赖保留。'
        say "失败记录（仅 root 可读）：$APP_STATE/$APP_NAME-last-error.log"
    fi
    [[ -z $APP_WORK ]] || rm -rf -- "$APP_WORK"
    exit "$result"
}

app_make_service() {
    # Both applications use their native binaries; no downloaded install script runs.
    local executable environment=''
    if [[ $APP_NAME == x-ui ]]; then
        executable=$APP_DIR/x-ui
        environment="Environment=XUI_DB_FOLDER=$APP_DATA XUI_BIN_FOLDER=$APP_DIR/bin XUI_LOG_FOLDER=$APP_DIR/log XUI_MAIN_FOLDER=$APP_DIR"
    else
        executable="$APP_DIR/openlist server --data $APP_DATA"
    fi
    cat > "$APP_UNIT" <<EOF
[Unit]
Description=$APP_NAME installed by BBR toolbox
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
$environment
ExecStart=$executable
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$APP_DIR $APP_DATA
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$APP_UNIT"
}

app_initialize() {
    local password username base
    password=$(app_payload field "$APP_RECORD" password)
    username=$(app_payload field "$APP_RECORD" username)
    base=$(app_payload field "$APP_RECORD" base)
    install -d -m 700 "$APP_DATA/tls"
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
        -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' \
        -keyout "$APP_DATA/tls/key.pem" -out "$APP_DATA/tls/cert.pem" > "$APP_WORK/tls.log" 2>&1
    if [[ $APP_NAME == x-ui ]]; then
        install -d -m 700 "$APP_DIR/log"
        (
            export XUI_DB_FOLDER=$APP_DATA XUI_BIN_FOLDER=$APP_DIR/bin XUI_LOG_FOLDER=$APP_DIR/log
            cd "$APP_DIR"
            ./x-ui setting -username "$username" -password "$password" -port "$APP_PORT" -webBasePath "$base" \
                -webCert "$APP_DATA/tls/cert.pem" -webCertKey "$APP_DATA/tls/key.pem"
        ) > "$APP_WORK/initialize.log" 2>&1
        app_payload x-ui-config "$APP_RECORD"
    else
        app_payload openlist-config "$APP_RECORD"
        OPENLIST_ADMIN_PASSWORD=$password "$APP_DIR/openlist" admin --data "$APP_DATA" > "$APP_WORK/initialize.log" 2>&1
    fi
    unset password
}

install_panel_app() (
    app_paths "$1"
    if (( DRY_RUN )); then
        say "[预览] 安装 $APP_NAME 官方最新稳定版（amd64 / arm64），冻结本次版本并核对 SHA-256；自动选择空闲端口、生成随机密码与 HTTPS 自签证书，启用开机启动。"
        say '[预览] 安装成功后集中显示访问地址、账号、密码和管理命令；已有安装不覆盖。'
        return
    fi
    need systemctl
    if [[ -f $APP_RECORD && ! -L $APP_RECORD ]]; then
        say '已由本脚本安装；保留现有版本、数据和密码，显示当前信息。'
        app_payload report "$APP_RECORD"
        return
    fi
    app_check_new
    app_architecture
    apt-get update
    apt-get install -y --no-install-recommends --no-remove ca-certificates curl python3 openssl
    [[ ! -L $APP_STATE ]] || die '应用记录目录不能是符号链接。'
    install -d -m 700 "$APP_STATE"
    APP_WORK=$(mktemp -d "$APP_STATE/install.XXXXXX")
    APP_COMPLETE=0; APP_DIR_CREATED=0; APP_DATA_CREATED=0; APP_UNIT_CREATED=0; APP_RECORD_CREATED=0
    trap app_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    app_asset
    say "正在下载并校验 $APP_NAME $APP_VERSION（$APP_ARCH）。"
    download_verified "$APP_URL" "$APP_WORK/package.tar.gz" "$APP_SHA"
    app_payload extract "$APP_NAME" "$APP_WORK/package.tar.gz" "$APP_WORK/stage" "$APP_ARCH"
    APP_PORT=$(app_payload port "$APP_PORT")
    mkdir -m 755 -- "$APP_DIR"
    APP_DIR_CREATED=1
    if [[ $APP_NAME == x-ui ]]; then
        cp -a -- "$APP_WORK/stage/x-ui/." "$APP_DIR/"
    else
        install -m 755 "$APP_WORK/stage/openlist" "$APP_DIR/openlist"
    fi
    mkdir -m 700 -- "$APP_DATA"
    APP_DATA_CREATED=1
    APP_RECORD_CREATED=1
    app_payload record "$APP_NAME" "$APP_RECORD" "$APP_VERSION" "$APP_DIR" "$APP_DATA" "$APP_PORT" "$APP_WORK/selected-release.json"
    app_initialize
    APP_UNIT_CREATED=1
    app_make_service
    systemctl daemon-reload
    systemctl enable --now "$APP_NAME.service"
    local attempt
    for attempt in {1..30}; do
        if systemctl is-active --quiet "$APP_NAME.service" && app_payload verify "$APP_RECORD" > "$APP_WORK/verify.log" 2>&1; then
            APP_COMPLETE=1
            break
        fi
        sleep 1
    done
    (( APP_COMPLETE )) || die '应用启动或实际登录验证失败，未宣告安装成功。'
    say '安装完成，已启用开机启动。'
    app_payload report "$APP_RECORD"
)

show_panel_apps() {
    if (( DRY_RUN )); then say '[预览] 读取已安装 3X-UI / OpenList 的当前访问与登录信息。'; return; fi
    need python3
    local app found=0
    for app in x-ui openlist; do
        app_paths "$app"
        if [[ -f $APP_RECORD && ! -L $APP_RECORD ]]; then
            found=1
            # Independent reports: a broken app must not hide the other one's information.
            app_payload report "$APP_RECORD" || say "$app 信息读取失败，请先检查其配置和服务。"
        fi
    done
    (( found )) || say '暂无本脚本安装的应用，请先选择 3X-UI 或 OpenList 安装。'
}
# END APP HELPERS

bbr_menu_action() {
    DRY_RUN=0; CLOUD=auto; JOBS=; PROFILE=recovery
    select_profile
    case "$1" in
        1)
            menu_line title '选择 Guard7 R2 安装方式：'
            menu_line install '1、下载预编译包安装（amd64，推荐）'
            menu_line install '2、源码编译安装（amd64 / arm64）'
            menu_line exit '0、退出'
            menu_choice 1 2
            case "$REPLY" in 1) ACTION=install ;; 2) ACTION=build ;; esac ;;
        2) ACTION=status ;; 3) ACTION=restore ;; 4) ACTION=cleanup ;;
        5)
            menu_line title '选择 Nginx 安装方式：'
            menu_line install '1、下载预编译包安装（Ubuntu 24.04 amd64，推荐）'
            menu_line install '2、源码编译安装（官方最新稳定版）'
            menu_line exit '0、退出'
            menu_choice 1 2
            case "$REPLY" in 1) ACTION=nginx ;; 2) ACTION=nginx-source ;; esac ;;
        6) ACTION=x-ui ;; 7) ACTION=openlist ;; 8) ACTION='app-info' ;;
        9) ACTION=reboot ;;
        *) die '无效菜单选项。' ;;
    esac
    if [[ $ACTION == install || $ACTION == build ]]; then menu_cloud; fi
    if [[ $ACTION == build ]]; then
        while true; do
            read -r -p '编译并发数（留空自动，0 退出）：' JOBS || menu_exit
            [[ $JOBS != 0 ]] || menu_exit
            [[ -z $JOBS || $JOBS =~ ^[1-9][0-9]{0,2}$ ]] && break
            say '请输入 1–999，或留空自动选择。'
        done
    fi
    dispatch
}

menu() {
    require_menu_terminal
    while true; do
        say ''
        menu_line title "===== Guard 实验内核 $TOOL_VERSION ====="
        menu_line install '1、安装 Guard7 R2（预编译 / 源码）'
        menu_line info '2、查看系统与算法状态'
        menu_line recovery '3、恢复原有网络参数'
        menu_line danger '4、清理其他内核（仅保留当前 BBR）'
        say ''
        menu_line install '5、安装 Nginx（预编译 / 源码）'
        menu_line install '6、安装 3X-UI 面板'
        menu_line install '7、安装 OpenList 网盘'
        menu_line info '8、查看应用登录信息'
        say ''
        menu_line danger '9、重启系统'
        menu_line exit '0、退出'
        menu_choice 1 2 3 4 5 6 7 8 9
        run_menu_action bbr_menu_action "$REPLY"
    done
}

dispatch() {
    case "$ACTION" in
        status)
            cloud_status
            local congestion qdisc
            congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
            qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
            say "拥塞算法：${congestion:-未获取}    默认队列：${qdisc:-未获取}"
            [[ ! -e $STATE/cleanup-pending ]] || say '等待新内核启动检查和旧内核清理。'
            [[ ! -e $STATE/install-pending && ! -L $STATE/install-pending ]] || say '安装事务未完成，请先重试安装以恢复启动项与配置，不要重启。'
            [[ ! -e $STATE/cleanup-incomplete && ! -L $STATE/cleanup-incomplete ]] || say '内核清理未完成，请重试菜单 4；完成前不要重启。'
            return ;;
    esac
    if (( !DRY_RUN )); then require_host; fi
    case "$ACTION" in
        install) install_prebuilt_kernel ;; build) build_kernel ;; enable) enable_bbr ;; restore) restore_bbr ;;
        cleanup) cleanup_old_kernels ;;
        reboot)
            [[ ! -e $STATE/install-pending && ! -L $STATE/install-pending ]] || die '安装恢复尚未完成，禁止从菜单重启；请先重试安装。'
            [[ ! -e $STATE/cleanup-incomplete && ! -L $STATE/cleanup-incomplete ]] || die '内核清理尚未完成，禁止从菜单重启；请先重试菜单 4。'
            reboot_host direct ;;
        nginx) install_nginx ;; nginx-source) install_nginx source ;;
        x-ui|openlist) install_panel_app "$ACTION" ;; app-info) show_panel_apps ;;
        *) die '无效内部操作。' ;;
    esac
}

main() {
    # Private entry for the installed health-check service, not a user command.
    if [[ $# == 1 && $1 == --internal-cleanup && ${BASH_SOURCE[0]} == /usr/local/libexec/bbr-kernel ]]; then
        ACTION=cleanup; dispatch; return
    fi
    (( $# == 0 )) || die '已改为中文数字菜单，请直接运行 sudo bash bbr.sh，不要附加命令或参数。'
    require_menu_terminal
    run_latest_release bbr.sh "${BASH_SOURCE[0]}"
    menu
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
