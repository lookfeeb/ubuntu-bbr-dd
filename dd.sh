#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
TOOL_VERSION=2.4.9
DRY_RUN=0
ACTION=menu
CLOUD=auto
SYS_ROOT=/sys
NIC_NAMES=()
NIC_DRIVERS=()
HAS_GVNIC=0
STATE=/var/lib/ubuntu-dd
REINSTALL_COMMIT=8ac9db68f9bca0b26c4143b2f3e206f2aa342d6b
REINSTALL_BUNDLE_SHA256=e16ac96823636556b0281ca85074f29c534e8c3f0be0c6b30c26a44eb5bb86bb
UBUNTU_VERSION=24.04
TEST_NETWORK=0
CACHE_MODE=auto

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

# BEGIN DD DISK HELPERS
# Shared by the host preparation and Alpine installer. Never trusts device order.
# shellcheck disable=SC3043,SC2154
dd_disk_fail() { echo "DD disk check stopped: $*" >&2; exit 1; }

dd_scsi_properties() {
    local probe
    for probe in /usr/lib/udev/scsi_id /lib/udev/scsi_id; do
        [ -x "$probe" ] || continue
        "$probe" --whitelisted --export --device="$1"
        return $?
    done
    return 1
}

dd_disk_field() {
    local value properties
    value=$(lsblk --nodeps --noheadings --raw --output "$2" "$1") || dd_disk_fail "Cannot read $2 for $1"
    # Alpine's lsblk lacks libudev, so a SCSI disk may have empty SERIAL/WWN
    # even though Ubuntu reported them. Query the same device directly; never
    # discard a recorded identifier or override a nonempty lsblk result.
    if [ -z "$value" ]; then
        case "$2" in
            SERIAL|WWN)
                if properties=$(dd_scsi_properties "$1"); then
                    if [ "$2" = SERIAL ]; then
                        value=$(printf '%s\n' "$properties" | sed -n 's/^ID_SERIAL_SHORT=//p')
                    else
                        value=$(printf '%s\n' "$properties" | sed -n 's/^ID_WWN_WITH_EXTENSION=//p')
                        [ -n "$value" ] || value=$(printf '%s\n' "$properties" | sed -n 's/^ID_WWN=//p')
                    fi
                fi ;;
        esac
    fi
    case "$value" in *'
'*) dd_disk_fail "Ambiguous $2 for $1" ;; esac
    printf '%s\n' "$value"
}

dd_disk_id() {
    local value
    value=$(dd_disk_field "$1" PTUUID) || exit 1
    value=$(printf '%s' "$value" | tr 'A-F' 'a-f')
    value=${value#0x}
    if [ -n "$value" ]; then
        printf '%s\n' "$value" | grep -Eq '^([0-9a-f]{8}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$' ||
            dd_disk_fail 'Invalid partition-table ID'
    fi
    printf '%s\n' "$value"
}

dd_disk_names() {
    local rows
    rows=$(lsblk --nodeps --noheadings --raw --output NAME,TYPE) || dd_disk_fail 'Cannot enumerate disks'
    printf '%s\n' "$rows" | awk '$2 == "disk" && $1 !~ /^(loop|sr|nbd|ram|zram)/ {print $1}'
}

dd_unique_disk() {
    local expected=$1 names name id found='' count=0
    [ -n "$expected" ] || dd_disk_fail 'Missing expected partition-table ID'
    names=$(dd_disk_names) || exit 1
    for name in $names; do
        case "$name" in ''|.*|*[!a-zA-Z0-9_.-]*) dd_disk_fail 'Unsupported disk name' ;; esac
        id=$(dd_disk_id "/dev/$name") || exit 1
        if [ "$id" = "$expected" ]; then
            found=$name
            count=$((count + 1))
        fi
    done
    [ "$count" = 1 ] || dd_disk_fail "Expected exactly one target disk, found $count matching partition-table IDs"
    printf '%s\n' "$found"
}

dd_verify_disk_identity() {
    local device=$1 expected selected value field recorded
    [ "$(cat "$DD_BUNDLE/disk-identity-version")" = 1 ] || dd_disk_fail 'Missing or unsupported disk identity record'
    expected=$(cat "$DD_BUNDLE/disk-ptuuid") || dd_disk_fail 'Missing target partition-table ID'
    selected=$(dd_unique_disk "$expected") || exit 1
    [ "$device" = "/dev/$selected" ] || dd_disk_fail 'Selected target no longer matches the prepared disk'
    value=$(blockdev --getsize64 "$device") || dd_disk_fail 'Cannot read target capacity'
    case "$value" in ''|0|*[!0-9]*) dd_disk_fail 'Invalid disk capacity' ;; esac
    [ "$value" = "$(cat "$DD_BUNDLE/disk-bytes")" ] || dd_disk_fail 'Target disk capacity changed'
    for field in SERIAL WWN; do
        recorded=$(cat "$DD_BUNDLE/disk-$field") || dd_disk_fail "Missing recorded $field"
        if [ -n "$recorded" ]; then
            value=$(dd_disk_field "$device" "$field") || exit 1
            [ "$value" = "$recorded" ] || dd_disk_fail "Target disk $field changed or is unavailable"
        fi
    done
}

dd_record_disk_identity() {
    local device=$1 id value field
    id=$(dd_disk_id "$device") || exit 1
    [ -n "$id" ] || dd_disk_fail 'Target has no partition-table ID'
    value=$(blockdev --getsize64 "$device") || dd_disk_fail 'Cannot read target capacity'
    case "$value" in ''|0|*[!0-9]*) dd_disk_fail 'Invalid disk capacity' ;; esac
    printf '%s\n' "$value" > "$DD_BUNDLE/disk-bytes"
    printf '%s\n' "$id" > "$DD_BUNDLE/disk-ptuuid"
    for field in SERIAL WWN; do
        value=$(dd_disk_field "$device" "$field") || exit 1
        printf '%s\n' "$value" > "$DD_BUNDLE/disk-$field"
    done
    printf '1\n' > "$DD_BUNDLE/disk-identity-version"
    dd_verify_disk_identity "$device"
}

dd_find_target_disk() {
    local expected selected cmdline_id
    expected=$(cat "$DD_BUNDLE/disk-ptuuid") || dd_disk_fail 'Missing prepared target identity'
    cmdline_id=$(printf '%s' "${main_disk:-}" | tr 'A-F' 'a-f')
    cmdline_id=${cmdline_id#0x}
    [ "$cmdline_id" = "$expected" ] || dd_disk_fail 'Boot target differs from prepared target'
    selected=$(dd_unique_disk "$expected") || exit 1
    dd_verify_disk_identity "/dev/$selected"
    # Consumed by the upstream installer after this shared helper returns.
    # shellcheck disable=SC2034
    xda=$selected
}
# END DD DISK HELPERS

unique_disk_for() {
    local topology disks
    topology=$(lsblk -s -n -r -p -o NAME,TYPE "$1") || die '读取磁盘拓扑失败。'
    disks=$(printf '%s\n' "$topology" | awk '$2 == "disk" {print $1}' | sort -u)
    [[ -n $disks && $disks != *$'\n'* ]] || die '系统卷跨多个磁盘或无法识别，拒绝自动重装。'
    printf '%s\n' "$disks"
}

detect_system_disk() {
    need findmnt; need lsblk; need readlink
    local source fs line disk
    source=$(findmnt -n -o SOURCE /)
    fs=$(findmnt -n -o FSTYPE /)
    case "$fs" in ext4|ext3|xfs) ;; *) die "根文件系统 $fs 尚未验证，不进行重装。" ;; esac
    source=$(readlink -f -- "$source")
    [[ -b $source ]] || die '无法确定根文件系统对应的块设备。'
    SYSTEM_DISK=$(unique_disk_for "$source")
    [[ -b $SYSTEM_DISK && $(lsblk -d -n -o TYPE "$SYSTEM_DISK") == disk ]] || die '目标不是完整磁盘。'
    local transport device_path
    transport=$(lsblk -d -n -o TRAN "$SYSTEM_DISK")
    device_path=$(readlink -f "$SYS_ROOT/class/block/${SYSTEM_DISK##*/}/device")
    [[ $transport != iscsi && $device_path != *'/session'* ]] || die '暂不支持 iSCSI 系统盘。'
    # 分离的 /boot 或 EFI 会让引导修改牵涉另一块盘，因此本工具拒绝这种布局。
    for line in /boot /boot/efi /efi; do
        [[ -d $line ]] || continue
        source=$(findmnt -n -o SOURCE -T "$line")
        source=$(readlink -f -- "$source")
        disk=$(unique_disk_for "$source")
        [[ $disk == "$SYSTEM_DISK" ]] || die "$line 位于其他磁盘，暂不支持此布局。"
    done
}

prepare_engine() {
    need python3
    local archive=$STATE/reinstall-$REINSTALL_COMMIT.tar.gz
    download_verified "https://codeload.github.com/bin456789/reinstall/tar.gz/$REINSTALL_COMMIT" "$archive" "$REINSTALL_BUNDLE_SHA256" 1
    DD_BUNDLE=$(mktemp -d "$STATE/engine.XXXXXX")
    export DD_BUNDLE
    engine_tools build "$archive" "$DD_BUNDLE"
    ENGINE=$DD_BUNDLE/reinstall.sh
    chmod 700 "$ENGINE"
}

# BEGIN DD ENGINE
engine_tools() {
    python3 - "$@" <<'PY_DD'
"""Version-locked Ubuntu-only adapter for bin456789/reinstall; never runs it.

The release script embeds this module and its assets. Every patch anchor must
match exactly once; upstream changes require explicit review and a new pin.
"""
import base64
import hashlib
from datetime import datetime
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import urllib.request

COMMIT = '8ac9db68f9bca0b26c4143b2f3e206f2aa342d6b'
ARCHIVE_SHA = 'e16ac96823636556b0281ca85074f29c534e8c3f0be0c6b30c26a44eb5bb86bb'
ASSETS = {"dd_disk.sh": "IyEvYmluL3NoCiMgc2hlbGxjaGVjayBzaGVsbD1kYXNoCiMgQkVHSU4gREQgRElTSyBIRUxQRVJTCiMgU2hhcmVkIGJ5IHRoZSBob3N0IHByZXBhcmF0aW9uIGFuZCBBbHBpbmUgaW5zdGFsbGVyLiBOZXZlciB0cnVzdHMgZGV2aWNlIG9yZGVyLgojIHNoZWxsY2hlY2sgZGlzYWJsZT1TQzMwNDMsU0MyMTU0CmRkX2Rpc2tfZmFpbCgpIHsgZWNobyAiREQgZGlzayBjaGVjayBzdG9wcGVkOiAkKiIgPiYyOyBleGl0IDE7IH0KCmRkX3Njc2lfcHJvcGVydGllcygpIHsKICAgIGxvY2FsIHByb2JlCiAgICBmb3IgcHJvYmUgaW4gL3Vzci9saWIvdWRldi9zY3NpX2lkIC9saWIvdWRldi9zY3NpX2lkOyBkbwogICAgICAgIFsgLXggIiRwcm9iZSIgXSB8fCBjb250aW51ZQogICAgICAgICIkcHJvYmUiIC0td2hpdGVsaXN0ZWQgLS1leHBvcnQgLS1kZXZpY2U9IiQxIgogICAgICAgIHJldHVybiAkPwogICAgZG9uZQogICAgcmV0dXJuIDEKfQoKZGRfZGlza19maWVsZCgpIHsKICAgIGxvY2FsIHZhbHVlIHByb3BlcnRpZXMKICAgIHZhbHVlPSQobHNibGsgLS1ub2RlcHMgLS1ub2hlYWRpbmdzIC0tcmF3IC0tb3V0cHV0ICIkMiIgIiQxIikgfHwgZGRfZGlza19mYWlsICJDYW5ub3QgcmVhZCAkMiBmb3IgJDEiCiAgICAjIEFscGluZSdzIGxzYmxrIGxhY2tzIGxpYnVkZXYsIHNvIGEgU0NTSSBkaXNrIG1heSBoYXZlIGVtcHR5IFNFUklBTC9XV04KICAgICMgZXZlbiB0aG91Z2ggVWJ1bnR1IHJlcG9ydGVkIHRoZW0uIFF1ZXJ5IHRoZSBzYW1lIGRldmljZSBkaXJlY3RseTsgbmV2ZXIKICAgICMgZGlzY2FyZCBhIHJlY29yZGVkIGlkZW50aWZpZXIgb3Igb3ZlcnJpZGUgYSBub25lbXB0eSBsc2JsayByZXN1bHQuCiAgICBpZiBbIC16ICIkdmFsdWUiIF07IHRoZW4KICAgICAgICBjYXNlICIkMiIgaW4KICAgICAgICAgICAgU0VSSUFMfFdXTikKICAgICAgICAgICAgICAgIGlmIHByb3BlcnRpZXM9JChkZF9zY3NpX3Byb3BlcnRpZXMgIiQxIik7IHRoZW4KICAgICAgICAgICAgICAgICAgICBpZiBbICIkMiIgPSBTRVJJQUwgXTsgdGhlbgogICAgICAgICAgICAgICAgICAgICAgICB2YWx1ZT0kKHByaW50ZiAnJXNcbicgIiRwcm9wZXJ0aWVzIiB8IHNlZCAtbiAncy9eSURfU0VSSUFMX1NIT1JUPS8vcCcpCiAgICAgICAgICAgICAgICAgICAgZWxzZQogICAgICAgICAgICAgICAgICAgICAgICB2YWx1ZT0kKHByaW50ZiAnJXNcbicgIiRwcm9wZXJ0aWVzIiB8IHNlZCAtbiAncy9eSURfV1dOX1dJVEhfRVhURU5TSU9OPS8vcCcpCiAgICAgICAgICAgICAgICAgICAgICAgIFsgLW4gIiR2YWx1ZSIgXSB8fCB2YWx1ZT0kKHByaW50ZiAnJXNcbicgIiRwcm9wZXJ0aWVzIiB8IHNlZCAtbiAncy9eSURfV1dOPS8vcCcpCiAgICAgICAgICAgICAgICAgICAgZmkKICAgICAgICAgICAgICAgIGZpIDs7CiAgICAgICAgZXNhYwogICAgZmkKICAgIGNhc2UgIiR2YWx1ZSIgaW4gKicKJyopIGRkX2Rpc2tfZmFpbCAiQW1iaWd1b3VzICQyIGZvciAkMSIgOzsgZXNhYwogICAgcHJpbnRmICclc1xuJyAiJHZhbHVlIgp9CgpkZF9kaXNrX2lkKCkgewogICAgbG9jYWwgdmFsdWUKICAgIHZhbHVlPSQoZGRfZGlza19maWVsZCAiJDEiIFBUVVVJRCkgfHwgZXhpdCAxCiAgICB2YWx1ZT0kKHByaW50ZiAnJXMnICIkdmFsdWUiIHwgdHIgJ0EtRicgJ2EtZicpCiAgICB2YWx1ZT0ke3ZhbHVlIzB4fQogICAgaWYgWyAtbiAiJHZhbHVlIiBdOyB0aGVuCiAgICAgICAgcHJpbnRmICclc1xuJyAiJHZhbHVlIiB8IGdyZXAgLUVxICdeKFswLTlhLWZdezh9fFswLTlhLWZdezh9LVswLTlhLWZdezR9LVswLTlhLWZdezR9LVswLTlhLWZdezR9LVswLTlhLWZdezEyfSkkJyB8fAogICAgICAgICAgICBkZF9kaXNrX2ZhaWwgJ0ludmFsaWQgcGFydGl0aW9uLXRhYmxlIElEJwogICAgZmkKICAgIHByaW50ZiAnJXNcbicgIiR2YWx1ZSIKfQoKZGRfZGlza19uYW1lcygpIHsKICAgIGxvY2FsIHJvd3MKICAgIHJvd3M9JChsc2JsayAtLW5vZGVwcyAtLW5vaGVhZGluZ3MgLS1yYXcgLS1vdXRwdXQgTkFNRSxUWVBFKSB8fCBkZF9kaXNrX2ZhaWwgJ0Nhbm5vdCBlbnVtZXJhdGUgZGlza3MnCiAgICBwcmludGYgJyVzXG4nICIkcm93cyIgfCBhd2sgJyQyID09ICJkaXNrIiAmJiAkMSAhfiAvXihsb29wfHNyfG5iZHxyYW18enJhbSkvIHtwcmludCAkMX0nCn0KCmRkX3VuaXF1ZV9kaXNrKCkgewogICAgbG9jYWwgZXhwZWN0ZWQ9JDEgbmFtZXMgbmFtZSBpZCBmb3VuZD0nJyBjb3VudD0wCiAgICBbIC1uICIkZXhwZWN0ZWQiIF0gfHwgZGRfZGlza19mYWlsICdNaXNzaW5nIGV4cGVjdGVkIHBhcnRpdGlvbi10YWJsZSBJRCcKICAgIG5hbWVzPSQoZGRfZGlza19uYW1lcykgfHwgZXhpdCAxCiAgICBmb3IgbmFtZSBpbiAkbmFtZXM7IGRvCiAgICAgICAgY2FzZSAiJG5hbWUiIGluICcnfC4qfCpbIWEtekEtWjAtOV8uLV0qKSBkZF9kaXNrX2ZhaWwgJ1Vuc3VwcG9ydGVkIGRpc2sgbmFtZScgOzsgZXNhYwogICAgICAgIGlkPSQoZGRfZGlza19pZCAiL2Rldi8kbmFtZSIpIHx8IGV4aXQgMQogICAgICAgIGlmIFsgIiRpZCIgPSAiJGV4cGVjdGVkIiBdOyB0aGVuCiAgICAgICAgICAgIGZvdW5kPSRuYW1lCiAgICAgICAgICAgIGNvdW50PSQoKGNvdW50ICsgMSkpCiAgICAgICAgZmkKICAgIGRvbmUKICAgIFsgIiRjb3VudCIgPSAxIF0gfHwgZGRfZGlza19mYWlsICJFeHBlY3RlZCBleGFjdGx5IG9uZSB0YXJnZXQgZGlzaywgZm91bmQgJGNvdW50IG1hdGNoaW5nIHBhcnRpdGlvbi10YWJsZSBJRHMiCiAgICBwcmludGYgJyVzXG4nICIkZm91bmQiCn0KCmRkX3ZlcmlmeV9kaXNrX2lkZW50aXR5KCkgewogICAgbG9jYWwgZGV2aWNlPSQxIGV4cGVjdGVkIHNlbGVjdGVkIHZhbHVlIGZpZWxkIHJlY29yZGVkCiAgICBbICIkKGNhdCAiJEREX0JVTkRMRS9kaXNrLWlkZW50aXR5LXZlcnNpb24iKSIgPSAxIF0gfHwgZGRfZGlza19mYWlsICdNaXNzaW5nIG9yIHVuc3VwcG9ydGVkIGRpc2sgaWRlbnRpdHkgcmVjb3JkJwogICAgZXhwZWN0ZWQ9JChjYXQgIiRERF9CVU5ETEUvZGlzay1wdHV1aWQiKSB8fCBkZF9kaXNrX2ZhaWwgJ01pc3NpbmcgdGFyZ2V0IHBhcnRpdGlvbi10YWJsZSBJRCcKICAgIHNlbGVjdGVkPSQoZGRfdW5pcXVlX2Rpc2sgIiRleHBlY3RlZCIpIHx8IGV4aXQgMQogICAgWyAiJGRldmljZSIgPSAiL2Rldi8kc2VsZWN0ZWQiIF0gfHwgZGRfZGlza19mYWlsICdTZWxlY3RlZCB0YXJnZXQgbm8gbG9uZ2VyIG1hdGNoZXMgdGhlIHByZXBhcmVkIGRpc2snCiAgICB2YWx1ZT0kKGJsb2NrZGV2IC0tZ2V0c2l6ZTY0ICIkZGV2aWNlIikgfHwgZGRfZGlza19mYWlsICdDYW5ub3QgcmVhZCB0YXJnZXQgY2FwYWNpdHknCiAgICBjYXNlICIkdmFsdWUiIGluICcnfDB8KlshMC05XSopIGRkX2Rpc2tfZmFpbCAnSW52YWxpZCBkaXNrIGNhcGFjaXR5JyA7OyBlc2FjCiAgICBbICIkdmFsdWUiID0gIiQoY2F0ICIkRERfQlVORExFL2Rpc2stYnl0ZXMiKSIgXSB8fCBkZF9kaXNrX2ZhaWwgJ1RhcmdldCBkaXNrIGNhcGFjaXR5IGNoYW5nZWQnCiAgICBmb3IgZmllbGQgaW4gU0VSSUFMIFdXTjsgZG8KICAgICAgICByZWNvcmRlZD0kKGNhdCAiJEREX0JVTkRMRS9kaXNrLSRmaWVsZCIpIHx8IGRkX2Rpc2tfZmFpbCAiTWlzc2luZyByZWNvcmRlZCAkZmllbGQiCiAgICAgICAgaWYgWyAtbiAiJHJlY29yZGVkIiBdOyB0aGVuCiAgICAgICAgICAgIHZhbHVlPSQoZGRfZGlza19maWVsZCAiJGRldmljZSIgIiRmaWVsZCIpIHx8IGV4aXQgMQogICAgICAgICAgICBbICIkdmFsdWUiID0gIiRyZWNvcmRlZCIgXSB8fCBkZF9kaXNrX2ZhaWwgIlRhcmdldCBkaXNrICRmaWVsZCBjaGFuZ2VkIG9yIGlzIHVuYXZhaWxhYmxlIgogICAgICAgIGZpCiAgICBkb25lCn0KCmRkX3JlY29yZF9kaXNrX2lkZW50aXR5KCkgewogICAgbG9jYWwgZGV2aWNlPSQxIGlkIHZhbHVlIGZpZWxkCiAgICBpZD0kKGRkX2Rpc2tfaWQgIiRkZXZpY2UiKSB8fCBleGl0IDEKICAgIFsgLW4gIiRpZCIgXSB8fCBkZF9kaXNrX2ZhaWwgJ1RhcmdldCBoYXMgbm8gcGFydGl0aW9uLXRhYmxlIElEJwogICAgdmFsdWU9JChibG9ja2RldiAtLWdldHNpemU2NCAiJGRldmljZSIpIHx8IGRkX2Rpc2tfZmFpbCAnQ2Fubm90IHJlYWQgdGFyZ2V0IGNhcGFjaXR5JwogICAgY2FzZSAiJHZhbHVlIiBpbiAnJ3wwfCpbITAtOV0qKSBkZF9kaXNrX2ZhaWwgJ0ludmFsaWQgZGlzayBjYXBhY2l0eScgOzsgZXNhYwogICAgcHJpbnRmICclc1xuJyAiJHZhbHVlIiA+ICIkRERfQlVORExFL2Rpc2stYnl0ZXMiCiAgICBwcmludGYgJyVzXG4nICIkaWQiID4gIiRERF9CVU5ETEUvZGlzay1wdHV1aWQiCiAgICBmb3IgZmllbGQgaW4gU0VSSUFMIFdXTjsgZG8KICAgICAgICB2YWx1ZT0kKGRkX2Rpc2tfZmllbGQgIiRkZXZpY2UiICIkZmllbGQiKSB8fCBleGl0IDEKICAgICAgICBwcmludGYgJyVzXG4nICIkdmFsdWUiID4gIiRERF9CVU5ETEUvZGlzay0kZmllbGQiCiAgICBkb25lCiAgICBwcmludGYgJzFcbicgPiAiJEREX0JVTkRMRS9kaXNrLWlkZW50aXR5LXZlcnNpb24iCiAgICBkZF92ZXJpZnlfZGlza19pZGVudGl0eSAiJGRldmljZSIKfQoKZGRfZmluZF90YXJnZXRfZGlzaygpIHsKICAgIGxvY2FsIGV4cGVjdGVkIHNlbGVjdGVkIGNtZGxpbmVfaWQKICAgIGV4cGVjdGVkPSQoY2F0ICIkRERfQlVORExFL2Rpc2stcHR1dWlkIikgfHwgZGRfZGlza19mYWlsICdNaXNzaW5nIHByZXBhcmVkIHRhcmdldCBpZGVudGl0eScKICAgIGNtZGxpbmVfaWQ9JChwcmludGYgJyVzJyAiJHttYWluX2Rpc2s6LX0iIHwgdHIgJ0EtRicgJ2EtZicpCiAgICBjbWRsaW5lX2lkPSR7Y21kbGluZV9pZCMweH0KICAgIFsgIiRjbWRsaW5lX2lkIiA9ICIkZXhwZWN0ZWQiIF0gfHwgZGRfZGlza19mYWlsICdCb290IHRhcmdldCBkaWZmZXJzIGZyb20gcHJlcGFyZWQgdGFyZ2V0JwogICAgc2VsZWN0ZWQ9JChkZF91bmlxdWVfZGlzayAiJGV4cGVjdGVkIikgfHwgZXhpdCAxCiAgICBkZF92ZXJpZnlfZGlza19pZGVudGl0eSAiL2Rldi8kc2VsZWN0ZWQiCiAgICAjIENvbnN1bWVkIGJ5IHRoZSB1cHN0cmVhbSBpbnN0YWxsZXIgYWZ0ZXIgdGhpcyBzaGFyZWQgaGVscGVyIHJldHVybnMuCiAgICAjIHNoZWxsY2hlY2sgZGlzYWJsZT1TQzIwMzQKICAgIHhkYT0kc2VsZWN0ZWQKfQojIEVORCBERCBESVNLIEhFTFBFUlMK", "dd_packages.sh": "IyEvYmluL3NoCiMgc2hlbGxjaGVjayBzaGVsbD1kYXNoCiMgc2hlbGxjaGVjayBkaXNhYmxlPVNDMzA0MyxTQzIxNTQsU0MyMDg2LFNDMjA0NgojIFByZWZsaWdodCB1c2VzIGEgY2FjaGUtYmFja2VkIG92ZXJsYXkgb24gdGhlIGF1dGhlbnRpY2F0ZWQgcmVhZC1vbmx5IGltYWdlLgojIEFQVCBkb3dubG9hZHMgYW5kIGF1dGhlbnRpY2F0ZXMgcGFja2FnZXMgd2l0aG91dCBydW5uaW5nIG1haW50YWluZXIgc2NyaXB0cy4KZGRfcGFja2FnZV9wbGFuKCkgewogICAgcHJpbnRmICclc1xuJyAibGludXgtaW1hZ2UtJChnZXRfdWJ1bnR1X2tlcm5lbF9mbGF2b3IpIiBvcGVuc3NoLXNlcnZlciBuZXRwbGFuLmlvIGluaXRyYW1mcy10b29scwogICAgaWYgaXNfZWZpOyB0aGVuCiAgICAgICAgY2FzZSAiJCh1bmFtZSAtbSkiIGluCiAgICAgICAgICAgIHg4Nl82NCkgZWNobyBncnViLWVmaS1hbWQ2NC1zaWduZWQ7IGVjaG8gc2hpbS1zaWduZWQgOzsKICAgICAgICAgICAgYWFyY2g2NCkgZWNobyBncnViLWVmaS1hcm02NC1zaWduZWQ7IGVjaG8gc2hpbS1zaWduZWQgOzsKICAgICAgICBlc2FjCiAgICBlbHNlCiAgICAgICAgZWNobyBncnViLXBjCiAgICBmaQogICAgZ2V0X3Vjb2RlX2Zpcm13YXJlX3BrZ3MKfQoKZGRfdmVyaWZ5X3BhY2thZ2VfY2FjaGUoKSB7CiAgICBsb2NhbCBjYWNoZT0kMQogICAgaWYgWyAhIC1zICIkY2FjaGUvU0hBMjU2U1VNUyIgXSB8fCBbICEgLXMgIiRjYWNoZS9wbGFuIiBdOyB0aGVuIGRkX2ZhaWwgJ1BhY2thZ2UgY2FjaGUgaXMgaW5jb21wbGV0ZSc7IGZpCiAgICAoY2QgIiRjYWNoZSIgJiYgc2hhMjU2c3VtIC1jIFNIQTI1NlNVTVMgPi9kZXYvbnVsbCkgfHwgZGRfZmFpbCAnUGFja2FnZSBjYWNoZSBjaGVja3N1bSBmYWlsZWQnCn0KCmRkX2NhY2hlX3BhY2thZ2VzKCkgKAogICAgbG9jYWwgaW1hZ2Vfcm9vdD0kMSBzdGFnZT0iJEREX0NBQ0hFL3BhY2thZ2Utc3RhZ2UiIHdvcms9IiRERF9DQUNIRS9wYWNrYWdlLXdvcmsiIGZpbGUgcGtnIGtlcm5lbCBjb3VudD0wCiAgICBERF9QQUNLQUdFX0NBQ0hFPSIkRERfQ0FDSEUvcGFja2FnZXMiCiAgICBta2RpciAtcCAiJHN0YWdlIiAiJHdvcmsvdXBwZXIiICIkd29yay93b3JrIiAiJEREX1BBQ0tBR0VfQ0FDSEUiCiAgICBncmVwIC1xdyBvdmVybGF5IC9wcm9jL2ZpbGVzeXN0ZW1zIHx8IG1vZHByb2JlIG92ZXJsYXkKICAgIG1vdW50IC10IG92ZXJsYXkgb3ZlcmxheSAtbyAibG93ZXJkaXI9JGltYWdlX3Jvb3QsdXBwZXJkaXI9JHdvcmsvdXBwZXIsd29ya2Rpcj0kd29yay93b3JrIiAiJHN0YWdlIgogICAgdHJhcCAndW1vdW50ICIkc3RhZ2UvZGV2IiAyPi9kZXYvbnVsbCB8fCB0cnVlOyB1bW91bnQgIiRzdGFnZS9wcm9jIiAyPi9kZXYvbnVsbCB8fCB0cnVlOyB1bW91bnQgIiRzdGFnZSIgMj4vZGV2L251bGwgfHwgdHJ1ZScgRVhJVAogICAgbW91bnQgLS1iaW5kIC9kZXYgIiRzdGFnZS9kZXYiCiAgICBtb3VudCAtdCBwcm9jIHByb2MgIiRzdGFnZS9wcm9jIgogICAgIyBVbmxpbmsgdGhlIGltYWdlIHN5bWxpbmsgYmVmb3JlIGNvcHlpbmcsIHNvIGFuIGFic29sdXRlIHRhcmdldCBjYW5ub3QKICAgICMgcmVzb2x2ZSBvdXRzaWRlIHRoaXMgb3ZlcmxheSB3aGlsZSBwcmVwYXJpbmcgRE5TLgogICAgcm0gLWYgIiRzdGFnZS9ldGMvcmVzb2x2LmNvbmYiCiAgICBjcCAvZXRjL3Jlc29sdi5jb25mICIkc3RhZ2UvZXRjL3Jlc29sdi5jb25mIgogICAgZGRfcGFja2FnZV9wbGFuID4gIiRERF9QQUNLQUdFX0NBQ0hFL3BsYW4udW5zb3J0ZWQiCiAgICBzb3J0IC11ICIkRERfUEFDS0FHRV9DQUNIRS9wbGFuLnVuc29ydGVkIiA+ICIkRERfUEFDS0FHRV9DQUNIRS9wbGFuIgogICAgcm0gIiRERF9QQUNLQUdFX0NBQ0hFL3BsYW4udW5zb3J0ZWQiCiAgICBbIC1zICIkRERfUEFDS0FHRV9DQUNIRS9wbGFuIiBdIHx8IGRkX2ZhaWwgJ0VtcHR5IEFQVCBwcmVmZXRjaCBwbGFuJwogICAgY2hyb290ICIkc3RhZ2UiIGFwdC1nZXQgLW8gQVBUOjpVcGRhdGU6OkVycm9yLU1vZGU9YW55IC1vIEFjcXVpcmU6Okxhbmd1YWdlcz1ub25lIFwKICAgICAgICAtbyBBY3F1aXJlOjpSZXRyaWVzPTMgLW8gQWNxdWlyZTo6aHR0cDo6VGltZW91dD0zMCAtbyBBY3F1aXJlOjpodHRwczo6VGltZW91dD0zMCB1cGRhdGUKICAgICMgQWxyZWFkeSBpbnN0YWxsZWQgY3VycmVudCBwYWNrYWdlcyBhcmUgcHJlc2VudCBpbiB0aGUgc2lnbmVkIGltYWdlOyB0aGUKICAgICMgZmluYWwgb2ZmbGluZSB0cmFuc2FjdGlvbiBkb2VzIG5vdCByZWluc3RhbGwgdGhlbSBlaXRoZXIuCiAgICBERUJJQU5fRlJPTlRFTkQ9bm9uaW50ZXJhY3RpdmUgY2hyb290ICIkc3RhZ2UiIGFwdC1nZXQgLS1kb3dubG9hZC1vbmx5IC15IFwKICAgICAgICAtbyBBY3F1aXJlOjpMYW5ndWFnZXM9bm9uZSAtbyBBY3F1aXJlOjpSZXRyaWVzPTMgXAogICAgICAgIC1vIEFjcXVpcmU6Omh0dHA6OlRpbWVvdXQ9MzAgLW8gQWNxdWlyZTo6aHR0cHM6OlRpbWVvdXQ9MzAgaW5zdGFsbCAkKGNhdCAiJEREX1BBQ0tBR0VfQ0FDSEUvcGxhbiIpCiAgICBta2RpciAtcCAiJEREX1BBQ0tBR0VfQ0FDSEUvYXJjaGl2ZXMiICIkRERfUEFDS0FHRV9DQUNIRS9saXN0cyIKICAgIGZvciBmaWxlIGluICIkc3RhZ2UiL3Zhci9jYWNoZS9hcHQvYXJjaGl2ZXMvKi5kZWI7IGRvCiAgICAgICAgWyAtZiAiJGZpbGUiIF0gfHwgY29udGludWUKICAgICAgICBwa2c9JChjaHJvb3QgIiRzdGFnZSIgZHBrZy1kZWIgLWYgIi92YXIvY2FjaGUvYXB0L2FyY2hpdmVzLyR7ZmlsZSMjKi99IiBQYWNrYWdlKQogICAgICAgIGNhc2UgIiRwa2ciIGluCiAgICAgICAgICAgIGxpbnV4LWltYWdlLVswLTldKnxsaW51eC1tb2R1bGVzLSopCiAgICAgICAgICAgICAgICAjIEV4dHJhY3Qgb25seSB0byB0aGUgZGlzcG9zYWJsZSBvdmVybGF5LiBObyBtYWludGFpbmVyIHNjcmlwdHMuCiAgICAgICAgICAgICAgICBjaHJvb3QgIiRzdGFnZSIgZHBrZy1kZWIgLXggIi92YXIvY2FjaGUvYXB0L2FyY2hpdmVzLyR7ZmlsZSMjKi99IiAvIDs7CiAgICAgICAgZXNhYwogICAgICAgIG12ICIkZmlsZSIgIiRERF9QQUNLQUdFX0NBQ0hFL2FyY2hpdmVzLyIKICAgIGRvbmUKICAgIGNwIC1hICIkc3RhZ2UvdmFyL2xpYi9hcHQvbGlzdHMvLiIgIiRERF9QQUNLQUdFX0NBQ0hFL2xpc3RzLyIKICAgICMgVGhlIHN0b2NrIGdlbmVyaWMgaW1hZ2UgbWF5IGxhY2sgR1ZFLiBOb3cgaW5zcGVjdCB0aGUgc2VsZWN0ZWQgY2xvdWQKICAgICMga2VybmVsIGZyb20gYXV0aGVudGljYXRlZCAuZGVicywgYmVmb3JlIHRoZSB0YXJnZXQgZGlzayBpcyBtb2RpZmllZC4KICAgIGxvY2FsIGZsYXZvcgogICAgZmxhdm9yPSQoZ2V0X3VidW50dV9rZXJuZWxfZmxhdm9yKQogICAgY2FzZSAiJGZsYXZvciIgaW4gZ2NwfGF3c3xvcmFjbGV8YXp1cmV8aWJtfHZtd2FyZSkgOzsgKikgZmxhdm9yPWdlbmVyaWMgOzsgZXNhYwogICAgZm9yIGtlcm5lbCBpbiAiJHN0YWdlIi9saWIvbW9kdWxlcy8qLSIkZmxhdm9yIjsgZG8KICAgICAgICBbIC1kICIka2VybmVsIiBdIHx8IGNvbnRpbnVlCiAgICAgICAgY2hyb290ICIkc3RhZ2UiIGRlcG1vZCAtYSAiJHtrZXJuZWwjIyovfSIKICAgICAgICBkZF9jaGVja19rZXJuZWxfZHJpdmVycyAiJHN0YWdlIiAiJHtrZXJuZWwjIyovfSIKICAgICAgICBjb3VudD0kKChjb3VudCArIDEpKQogICAgZG9uZQogICAgWyAiJGNvdW50IiAtZ3QgMCBdIHx8IGRkX2ZhaWwgJ1NlbGVjdGVkIGtlcm5lbCBoYXMgbm8gbW9kdWxlIHRyZWUgaW4gY2FjaGUvaW1hZ2UnCiAgICAoY2QgIiRERF9QQUNLQUdFX0NBQ0hFIiAmJiBmaW5kIHBsYW4gYXJjaGl2ZXMgbGlzdHMgLXR5cGUgZiAtZXhlYyBzaGEyNTZzdW0ge30gXDsgPiBTSEEyNTZTVU1TKQogICAgZGRfdmVyaWZ5X3BhY2thZ2VfY2FjaGUgIiRERF9QQUNLQUdFX0NBQ0hFIgogICAgdW1vdW50ICIkc3RhZ2UvZGV2IgogICAgdW1vdW50ICIkc3RhZ2UvcHJvYyIKICAgIHVtb3VudCAiJHN0YWdlIgogICAgdHJhcCAtIEVYSVQKICAgICMgUGF0aHMgYXJlIGZpeGVkIGNoaWxkcmVuIG9mIHRoaXMgbmV3bHkgY3JlYXRlZCBjYWNoZSwgd2l0aCBhbGwKICAgICMgbmVzdGVkIG1vdW50cyByZW1vdmVkLiBGcmVlIGV4dHJhY3RlZCBtb2R1bGVzIGFuZCB0ZW1wb3JhcnkgQVBUIGRhdGEuCiAgICBybSAtcmYgLS0gIiR3b3JrIgopCgpkZF9zZWVkX3BhY2thZ2VzKCkgewogICAgbG9jYWwgcm9vdD0kMSBjYWNoZT0ke0REX1BBQ0tBR0VfU09VUkNFOi0vaW5zdGFsbGVyL2RkLXBhY2thZ2VzfQogICAgZGRfdmVyaWZ5X3BhY2thZ2VfY2FjaGUgIiRjYWNoZSIKICAgIG1rZGlyIC1wICIkcm9vdC92YXIvY2FjaGUvYXB0L2FyY2hpdmVzIiAiJHJvb3QvdmFyL2xpYi9hcHQvbGlzdHMiICIkcm9vdC92YXIvbGliL3VidW50dS1kZCIKICAgIGNwIC1hICIkY2FjaGUvYXJjaGl2ZXMvLiIgIiRyb290L3Zhci9jYWNoZS9hcHQvYXJjaGl2ZXMvIgogICAgY3AgLWEgIiRjYWNoZS9saXN0cy8uIiAiJHJvb3QvdmFyL2xpYi9hcHQvbGlzdHMvIgogICAgY3AgIiRjYWNoZS9wbGFuIiAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvcGFja2FnZS1wbGFuIgogICAgY3AgIiRjYWNoZS9TSEEyNTZTVU1TIiAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvcGFja2FnZS1jYWNoZS5zaGEyNTYiCiAgICB0b3VjaCAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvcGFja2FnZXMtcmVhZHkiCiAgICAjIFByZXNlcnZlIGFscmVhZHkgaW5zdGFsbGVkIHBsYW5uZWQgZGVwZW5kZW5jaWVzIHRocm91Z2ggdGhlIHVwc3RyZWFtCiAgICAjIGNsZWFudXAuIFRoZSBzZWxlY3RlZCBuZXcgY2xvdWQga2VybmVsIGlzIG1hcmtlZCBtYW51YWwgb24gaW5zdGFsbGF0aW9uLgogICAgbG9jYWwgcGtnCiAgICB3aGlsZSByZWFkIC1yIHBrZzsgZG8KICAgICAgICBpZiBjaHJvb3QgIiRyb290IiBkcGtnIC1zICIkcGtnIiA+L2Rldi9udWxsIDI+JjE7IHRoZW4gY2hyb290ICIkcm9vdCIgYXB0LW1hcmsgbWFudWFsICIkcGtnIjsgZmkKICAgIGRvbmUgPCAiJGNhY2hlL3BsYW4iCn0KCmRkX2FwdF91cGRhdGUoKSB7CiAgICBbIC1mICIkMS92YXIvbGliL3VidW50dS1kZC9wYWNrYWdlcy1yZWFkeSIgXSB8fCBkZF9mYWlsICdPZmZsaW5lIEFQVCBjYWNoZSB3YXMgbm90IHNlZWRlZCcKICAgICMgVGhlIGF1dGhlbnRpY2F0ZWQgaW5kZXhlcyB3ZXJlIGNvcGllZCBmcm9tIHByZWZsaWdodC4gTmV2ZXIgcmVmcmVzaAogICAgIyB0aGVtIGFmdGVyIGVyYXNpbmcgdGhlIGRpc2ssIHdoaWNoIGNvdWxkIHNlbGVjdCB1bmNhY2hlZCBwYWNrYWdlIHZlcnNpb25zLgp9CgpkZF9pbnN0YWxsX3BhY2thZ2VzKCkgewogICAgbG9jYWwgcm9vdD0kMQogICAgZGRfYXB0X3VwZGF0ZSAiJHJvb3QiCiAgICBpZiBkZF9kaXNrX2NhY2hlOyB0aGVuCiAgICAgICAgbWtkaXIgLXAgIiRyb290L2V0Yy9pbml0cmFtZnMtdG9vbHMvY29uZi5kIgogICAgICAgIHByaW50ZiAnQ09NUFJFU1M9Z3ppcFxuJyA+ICIkcm9vdC9ldGMvaW5pdHJhbWZzLXRvb2xzL2NvbmYuZC96ei1kZC1sb3dtZW0iCiAgICAgICAgZXhwb3J0IERQS0dfREVCX1RIUkVBRFNfTUFYPTEKICAgIGZpCiAgICAjIFJlcXVlc3QgZXZlcnkgcGxhbm5lZCBwYWNrYWdlIGFnYWluc3QgdGhlIHNhbWUgaW5kZXhlcy4gQWxyZWFkeSBjdXJyZW50CiAgICAjIHBhY2thZ2VzIHN0YXkgaW5zdGFsbGVkLCBhdm9pZGluZyBuZWVkbGVzcyBTU0gvYm9vdGxvYWRlciBwb3N0aW5zdCBydW5zLgogICAgIyAtLW5vLWRvd25sb2FkIHJlZnVzZXMgYW55IHVuYW50aWNpcGF0ZWQgZGVwZW5kZW5jeS4KICAgIERFQklBTl9GUk9OVEVORD1ub25pbnRlcmFjdGl2ZSBjaHJvb3QgIiRyb290IiBhcHQtZ2V0IC0tbm8tZG93bmxvYWQgLXkgaW5zdGFsbCAkKGNhdCAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvcGFja2FnZS1wbGFuIikKfQo=", "dd_resources.sh": "IyEvYmluL3NoCiMgc2hlbGxjaGVjayBzaGVsbD1kYXNoCiMgc2hlbGxjaGVjayBkaXNhYmxlPVNDMzA0MyxTQzIxNTQKIyBDb21tb24gcmVzb3VyY2UgYWRhcHRlciB1c2VkIGJ5IEJhc2ggKGhvc3QpIGFuZCBCdXN5Qm94IGFzaCAoaW5zdGFsbGVyKS4KIyBSZXR1cm4gMTI1IG9ubHkgd2hlbiB0aGUgcmVxdWVzdCBpcyBub3QgZm9yIHRoZSBwaW5uZWQgdXBzdHJlYW0gYnVuZGxlLgpkZF9yZXNvdXJjZSgpIHsKICAgIGxvY2FsIG1vZGU9IiQxIiB1cmw9Jycgb3V0cHV0PS0gYXJnIG5hbWUgZXhwZWN0ZWQgYWN0dWFsCiAgICBzaGlmdAogICAgaWYgWyAiJG1vZGUiID0gZG93bmxvYWQgXTsgdGhlbgogICAgICAgIHVybD0kMTsgb3V0cHV0PSQyCiAgICBlbHNlCiAgICAgICAgd2hpbGUgWyAiJCMiIC1ndCAwIF07IGRvCiAgICAgICAgICAgIGFyZz0kMTsgc2hpZnQKICAgICAgICAgICAgY2FzZSAiJGFyZyIgaW4KICAgICAgICAgICAgICAgIGh0dHBzOi8vcmF3LmdpdGh1YnVzZXJjb250ZW50LmNvbS9iaW40NTY3ODkvcmVpbnN0YWxsLyp8aHR0cHM6Ly9jbmIuY29vbC9iaW40NTY3ODkvcmVpbnN0YWxsLy0vZ2l0L3Jhdy8qKSB1cmw9JGFyZyA7OwogICAgICAgICAgICAgICAgLW98LUxvfC0tb3V0cHV0KSBbICIkbW9kZSIgPSBjdXJsIF0gfHwgY29udGludWU7IG91dHB1dD0kMTsgc2hpZnQgOzsKICAgICAgICAgICAgICAgIC1PKSBpZiBbICIkbW9kZSIgPSB3Z2V0IF07IHRoZW4gb3V0cHV0PSQxOyBzaGlmdDsgZWxzZSBvdXRwdXQ9YXV0bzsgZmkgOzsKICAgICAgICAgICAgICAgIC1PLSkgWyAiJG1vZGUiICE9IHdnZXQgXSB8fCBvdXRwdXQ9LSA7OwogICAgICAgICAgICAgICAgLUxPKSBvdXRwdXQ9YXV0byA7OwogICAgICAgICAgICBlc2FjCiAgICAgICAgZG9uZQogICAgZmkKICAgIGNhc2UgIiR1cmwiIGluCiAgICAgICAgaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL2JpbjQ1Njc4OS9yZWluc3RhbGwvKnxodHRwczovL2NuYi5jb29sL2JpbjQ1Njc4OS9yZWluc3RhbGwvLS9naXQvcmF3LyopIDs7CiAgICAgICAgKikgcmV0dXJuIDEyNSA7OwogICAgZXNhYwogICAgbmFtZT0ke3VybCMjKi99CiAgICBjYXNlICIkbmFtZSIgaW4gJyd8Lip8KlshYS16QS1aMC05Xy4tXSopIGVjaG8gJ0ludmFsaWQgYnVuZGxlIHJlc291cmNlJyA+JjI7IHJldHVybiAxIDs7IGVzYWMKICAgIFsgIiR7dXJsJS8qfSIgPSAiJGNvbmZob21lIiBdIHx8IHsgZWNobyAnVW5waW5uZWQgcmVzb3VyY2UgVVJMIHJlZnVzZWQnID4mMjsgcmV0dXJuIDE7IH0KICAgIGV4cGVjdGVkPSQoYXdrIC12IG49IiRuYW1lIiAnJDIgPT0gbiB7cHJpbnQgJDF9JyAiJEREX0JVTkRMRS9yZXNvdXJjZXMuc2hhMjU2IikgfHwgcmV0dXJuIDEKICAgIGlmIFsgLXogIiRleHBlY3RlZCIgXSB8fCBbICEgLWYgIiRERF9CVU5ETEUvJG5hbWUiIF07IHRoZW4gZWNobyAiTWlzc2luZyBwaW5uZWQgcmVzb3VyY2U6ICRuYW1lIiA+JjI7IHJldHVybiAxOyBmaQogICAgYWN0dWFsPSQoc2hhMjU2c3VtICIkRERfQlVORExFLyRuYW1lIikgfHwgcmV0dXJuIDEKICAgIFsgIiR7YWN0dWFsJSUgKn0iID0gIiRleHBlY3RlZCIgXSB8fCB7IGVjaG8gIlJlc291cmNlIGNoZWNrc3VtIGZhaWxlZDogJG5hbWUiID4mMjsgcmV0dXJuIDE7IH0KICAgIFsgIiRvdXRwdXQiICE9IGF1dG8gXSB8fCBvdXRwdXQ9JG5hbWUKICAgIGlmIFsgIiRvdXRwdXQiID0gLSBdOyB0aGVuIGNhdCAiJEREX0JVTkRMRS8kbmFtZSI7IGVsc2UgY3AgIiRERF9CVU5ETEUvJG5hbWUiICIkb3V0cHV0IjsgZmkKfQo=", "dd_runtime.sh": "IyEvYmluL3NoCiMgTG9hZGVkIG9ubHkgYnkgdGhlIHBhdGNoZWQgQWxwaW5lIHRyYW5zLnNoLiBObyBhY3Rpb25zIHdoZW4gc291cmNlZCBpbiB0ZXN0cy4KIyBzaGVsbGNoZWNrIHNoZWxsPWRhc2gKIyBzaGVsbGNoZWNrIGRpc2FibGU9U0MzMDQzLFNDMjE1NApkZF9mYWlsKCkgeyBlY2hvICJERCBzdG9wcGVkOiAkKiIgPiYyOyBleGl0IDE7IH0KCiMgVGhpcyBpcyBhIHNhbWUtYm9vdCBmYWlsdXJlIGpvdXJuYWwsIG5ldmVyIGEgdG9rZW4gdGhhdCBza2lwcyB2ZXJpZmljYXRpb24uCiMgS2VlcCBpdCBvdXRzaWRlIHRoZSBzZWFsZWQgYnVuZGxlIGFuZCBvdXRzaWRlIHBhdGhzIGNsZWFyZWQgYnkgdXBzdHJlYW0uCmRkX2luc3RhbGxfYmVnaW4oKSB7CiAgICBERF9JTlNUQUxMX1NUQVRFPSR7RERfSU5TVEFMTF9TVEFURTotL3J1bi91YnVudHUtZGQtaW5zdGFsbH0KICAgIFsgISAtTCAiJEREX0lOU1RBTExfU1RBVEUiIF0gfHwgZGRfZmFpbCAnSW5zdGFsbGF0aW9uIGpvdXJuYWwgY2Fubm90IGJlIGEgc3ltbGluaycKICAgIG1rZGlyIC1wICIkRERfSU5TVEFMTF9TVEFURSIKICAgIGNobW9kIDcwMCAiJEREX0lOU1RBTExfU1RBVEUiCiAgICBta2RpciAiJEREX0lOU1RBTExfU1RBVEUvbG9jayIgMj4vZGV2L251bGwgfHwgZGRfZmFpbCAnQW5vdGhlciBvciBpbnRlcnJ1cHRlZCBpbnN0YWxsZXIgb3ducyB0aGUgam91cm5hbDsgaW5zcGVjdCBpdCBiZWZvcmUgcmV0cnlpbmcnCiAgICAjIEluc3BlY3QgdGhlIGJvdW5kYXJ5IG9ubHkgYWZ0ZXIgYWNxdWlyaW5nIHRoZSBsb2NrOiBhIHByZWNlZGluZyBhdHRlbXB0CiAgICAjIG1heSBoYXZlIGZhaWxlZCBiZXR3ZWVuIG91ciBpbml0aWFsIGVudHJ5IGFuZCB0aGUgc3VjY2Vzc2Z1bCBta2Rpci4KICAgIGlmIFsgLWUgIiRERF9JTlNUQUxMX1NUQVRFL2Rlc3RydWN0aXZlIiBdOyB0aGVuCiAgICAgICAgcm1kaXIgIiRERF9JTlNUQUxMX1NUQVRFL2xvY2siIDI+L2Rldi9udWxsIHx8IHRydWUKICAgICAgICBkZF9mYWlsICJBIHByZXZpb3VzIGF0dGVtcHQgc3RhcnRlZCBkaXNrIHdyaXRlcy4gQXV0b21hdGljIHJlc3RhcnQgaXMgcmVmdXNlZDsgaW5zcGVjdCAkRERfSU5TVEFMTF9TVEFURSBhbmQgL3JlaW5zdGFsbC5sb2cgZnJvbSB0aGUgaW5zdGFsbGVyIGNvbnNvbGUuIERvIG5vdCByZWJvb3QgYW4gaW5jb21wbGV0ZSB0YXJnZXQuIgogICAgZmkKICAgIEREX0lOU1RBTExfQUNUSVZFPTEKICAgIEREX0lOU1RBTExfUEhBU0U9cHJlZmxpZ2h0CiAgICB0cmFwICdkZF9pbnN0YWxsX2V4aXQgJD8nIEVYSVQKICAgIHRyYXAgJ2V4aXQgMTMwJyBJTlQKICAgIHRyYXAgJ2V4aXQgMTQzJyBURVJNCiAgICB0cmFwICdleGl0IDEyOScgSFVQCiAgICBybSAtZiAiJEREX0lOU1RBTExfU1RBVEUvZXhpdC1zdGF0dXMiCiAgICBkZF9pbnN0YWxsX3N0YWdlIHByZWZsaWdodAp9CgpkZF9pbnN0YWxsX3N0YWdlKCkgewogICAgRERfSU5TVEFMTF9QSEFTRT0kMQogICAgWyAiJHtERF9JTlNUQUxMX0FDVElWRTotMH0iID0gMSBdIHx8IHJldHVybiAwCiAgICAjIEFsbCB2YWx1ZXMgY29tZSBmcm9tIHRoZSBpbnN0YWxsZXIsIG5vdCBjcmVkZW50aWFscyBvciB1c2VyLWRhdGEuCiAgICAodW1hc2sgMDc3OyBwcmludGYgJ3BoYXNlPSVzXG5jYWNoZT0lc1xuZGlzaz0lc1xuJyAiJEREX0lOU1RBTExfUEhBU0UiIFwKICAgICAgICAiJHtERF9DQUNIRV9NT0RFOi11bmtub3dufSIgIiR7eGRhOi11bmtub3dufSIgPiAiJEREX0lOU1RBTExfU1RBVEUvc3RhdHVzLm5ldyIpCiAgICBtdiAtZiAiJEREX0lOU1RBTExfU1RBVEUvc3RhdHVzLm5ldyIgIiRERF9JTlNUQUxMX1NUQVRFL3N0YXR1cyIKICAgIGVjaG8gIkREIHN0YWdlOiAkRERfSU5TVEFMTF9QSEFTRSIKfQoKZGRfaW5zdGFsbF9leGl0KCkgewogICAgbG9jYWwgc3RhdHVzPSQxCiAgICB0cmFwIC0gRVhJVCBJTlQgVEVSTSBIVVAKICAgICMgQSBzdWNjZXNzZnVsIHByZS1wYXJ0aXRpb24gcmV0cnkgbXVzdCByZXBsYWNlIHRoZSBwcmV2aW91cyBmYWlsdXJlIGNvZGUuCiAgICBwcmludGYgJyVzXG4nICIkc3RhdHVzIiA+ICIkRERfSU5TVEFMTF9TVEFURS9leGl0LXN0YXR1cyIgfHwgdHJ1ZQogICAgaWYgWyAiJHN0YXR1cyIgPSAwIF07IHRoZW4KICAgICAgICBybWRpciAiJEREX0lOU1RBTExfU1RBVEUvbG9jayIgMj4vZGV2L251bGwgfHwgdHJ1ZQogICAgICAgIHJldHVybiAwCiAgICBmaQogICAgZWNobyAiREQgZmFpbGVkIGF0IHN0YWdlICR7RERfSU5TVEFMTF9QSEFTRTotdW5rbm93bn07IGF1dG9tYXRpYyByZWJvb3Qgd2FzIG5vdCByZWFjaGVkLiIgPiYyCiAgICBpZiBbIC1lICIkRERfSU5TVEFMTF9TVEFURS9kZXN0cnVjdGl2ZSIgXTsgdGhlbgogICAgICAgIGVjaG8gJ0Rpc2sgd3JpdGVzIGhhdmUgc3RhcnRlZDsgdGhlIG9sZCBzeXN0ZW0gY2Fubm90IGJlIGFzc3VtZWQgcmVjb3ZlcmFibGUuIEtlZXAgdGhlIGluc3RhbGxlciBydW5uaW5nIGFuZCBpbnNwZWN0IC9yZWluc3RhbGwubG9nLiBSZS1ydW5uaW5nIHRyYW5zLnNoIGlzIGJsb2NrZWQgdG8gcHJldmVudCBhbm90aGVyIGVyYXNlLicgPiYyCiAgICBlbHNlCiAgICAgICAgZWNobyAnUGFydGl0aW9uaW5nIGhhcyBub3Qgc3RhcnRlZDsgdGhpcyBhdHRlbXB0IGRpZCBub3QgZXJhc2UgdGhlIG9yaWdpbmFsIGxheW91dC4nID4mMgogICAgZmkKICAgICMgUGVyc2lzdCBvbmx5IG9uIHRoZSBhbHJlYWR5LW1vdW50ZWQgY2FjaGU7IG5ldmVyIG1vdW50IG9yIGFsdGVyIGEgZGlzawogICAgIyB3aGlsZSBoYW5kbGluZyBhbiBlcnJvciwgYW5kIG5ldmVyIGRpc3R1cmIgaXRzIGFjdGl2ZSBzd2FwLgogICAgaWYgZGRfZGlza19jYWNoZSAmJiBtb3VudHBvaW50IC1xIC9pbnN0YWxsZXIgJiYKICAgICAgIFsgIiQocmVhZGxpbmsgLWYgIiQoZmluZG1udCAtbiAtbyBTT1VSQ0UgLS10YXJnZXQgL2luc3RhbGxlcikiKSIgPSAiJChyZWFkbGluayAtZiAiJHtkZXZfaW5zdGFsbGVyOi0vbm9uZXhpc3RlbnR9IikiIF07IHRoZW4KICAgICAgICAoCiAgICAgICAgICAgIHNldCArZQogICAgICAgICAgICBta2RpciAtcCAvaW5zdGFsbGVyL2RkLWZhaWx1cmUKICAgICAgICAgICAgY2htb2QgNzAwIC9pbnN0YWxsZXIvZGQtZmFpbHVyZQogICAgICAgICAgICBjcCAiJEREX0lOU1RBTExfU1RBVEUvc3RhdHVzIiAiJEREX0lOU1RBTExfU1RBVEUvZXhpdC1zdGF0dXMiIC9pbnN0YWxsZXIvZGQtZmFpbHVyZS8KICAgICAgICAgICAgWyAhIC1mIC9yZWluc3RhbGwubG9nIF0gfHwgY3AgL3JlaW5zdGFsbC5sb2cgL2luc3RhbGxlci9kZC1mYWlsdXJlL3JlaW5zdGFsbC5sb2cKICAgICAgICAgICAgc3luYwogICAgICAgICkgfHwgdHJ1ZQogICAgZmkKICAgICMgUmV0YWluIG93bmVyc2hpcCB3aGlsZSB3cml0aW5nIGV2aWRlbmNlOyBhIHByZS1wYXJ0aXRpb24gcmV0cnkgbXVzdCBub3QKICAgICMgcmVwbGFjZSBzdGF0dXMgd2hpbGUgdGhpcyBhdHRlbXB0IGlzIHN0aWxsIHJlY29yZGluZyBpdHMgZmFpbHVyZS4KICAgIHJtZGlyICIkRERfSU5TVEFMTF9TVEFURS9sb2NrIiAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgICBleGl0ICIkc3RhdHVzIgp9CmRkX2h0dHBzKCkgewogICAgY29tbWFuZCBjdXJsIC0tZmFpbCAtLWxvY2F0aW9uIC0tcHJvdG8gJz1odHRwcycgLS1wcm90by1yZWRpciAnPWh0dHBzJyAtLXRsc3YxLjIgXAogICAgICAgIC0tcmV0cnkgMyAtLWNvbm5lY3QtdGltZW91dCAyMCAtLXNwZWVkLWxpbWl0IDEwMjQgLS1zcGVlZC10aW1lIDEyMCAiJEAiCn0KCmRkX2Rvd25sb2FkX2ltYWdlKCkgewogICAgbG9jYWwgdXJsPSQxIG91dHB1dD0kMiBieXRlcz0kMyBhdHRlbXB0PTEgc3RhdHVzIHNpemUgc3RhcnRlZAogICAgc3RhcnRlZD0kKGRhdGUgKyVzKQogICAgWyAhIC1MICIkb3V0cHV0IiBdIHx8IGRkX2ZhaWwgJ0ltYWdlIGNhY2hlIGNhbm5vdCBiZSBhIHN5bWxpbmsnCiAgICB3aGlsZSBbICIkYXR0ZW1wdCIgLWxlIDQgXTsgZG8KICAgICAgICBzaXplPTAKICAgICAgICBbICEgLWYgIiRvdXRwdXQiIF0gfHwgc2l6ZT0kKHN0YXQgLWMgJXMgIiRvdXRwdXQiKQogICAgICAgIFsgIiRzaXplIiAtbGUgIiRieXRlcyIgXSB8fCBkZF9mYWlsICdQYXJ0aWFsIGltYWdlIGV4Y2VlZHMgYXV0aGVudGljYXRlZCBzaXplJwogICAgICAgIGlmIFsgIiRzaXplIiA9ICIkYnl0ZXMiIF07IHRoZW4gYnJlYWs7IGZpCiAgICAgICAgIyBPbmUgcmV0cnkgYnVkZ2V0LiBjdXJsIHZhbGlkYXRlcyBDb250ZW50LVJhbmdlIGJlZm9yZSBhcHBlbmRpbmcsIGFuZAogICAgICAgICMgdGhlIGNhbGxlciBzdGlsbCB2ZXJpZmllcyB0aGUgZXhhY3Qgc2l6ZSBhbmQgc2lnbmVkIFNIQS0yNTYgaW4gZnVsbC4KICAgICAgICBpZiBkZF9odHRwcyAtLXJldHJ5IDAgLS1jb250aW51ZS1hdCAtIC0tbWF4LWZpbGVzaXplICIkYnl0ZXMiIC0tb3V0cHV0ICIkb3V0cHV0IiAiJHVybCI7IHRoZW4KICAgICAgICAgICAgYnJlYWsKICAgICAgICBlbHNlIHN0YXR1cz0kPzsgZmkKICAgICAgICBjYXNlICIkc3RhdHVzIiBpbgogICAgICAgICAgICAzM3wzNikgcm0gLWYgLS0gIiRvdXRwdXQiIDs7ICMgU2VydmVyIGRvZXMgbm90IHN1cHBvcnQgcmVzdW1pbmcuCiAgICAgICAgICAgIDV8Nnw3fDE4fDIyfDI4fDM1fDUyfDU1fDU2fDkyKSA7OyAjIEJvdW5kZWQgcmV0cmllcyBmb3IgdHJhbnNwb3J0IGVycm9ycy4KICAgICAgICAgICAgKikgZGRfZmFpbCAiSW1hZ2UgZG93bmxvYWQgZmFpbGVkIChjdXJsICRzdGF0dXMpIiA7OwogICAgICAgIGVzYWMKICAgICAgICBbICIkYXR0ZW1wdCIgLWx0IDQgXSB8fCBkZF9mYWlsICdJbWFnZSBkb3dubG9hZCByZXRyeSBsaW1pdCByZWFjaGVkJwogICAgICAgIGVjaG8gIkltYWdlIHRyYW5zZmVyIGludGVycnVwdGVkOyByZXRyeSAkYXR0ZW1wdC8zLCByZXRhaW5pbmcgcGFydGlhbCBkYXRhIHdoZXJlIHN1cHBvcnRlZC4iCiAgICAgICAgc2xlZXAgIiRhdHRlbXB0IgogICAgICAgIGF0dGVtcHQ9JCgoYXR0ZW1wdCArIDEpKQogICAgZG9uZQogICAgaWYgWyAhIC1mICIkb3V0cHV0IiBdIHx8IFsgIiQoc3RhdCAtYyAlcyAiJG91dHB1dCIpIiAhPSAiJGJ5dGVzIiBdOyB0aGVuIGRkX2ZhaWwgJ0luY29tcGxldGUgaW1hZ2UgZG93bmxvYWQnOyBmaQogICAgZWNobyAiSW1hZ2UgZG93bmxvYWQgY29tcGxldGVkOiAkYnl0ZXMgYnl0ZXMsICQoKCAkKGRhdGUgKyVzKSAtIHN0YXJ0ZWQgKSkgc2Vjb25kczsgc2lnbmF0dXJlIGhhc2ggdmVyaWZpY2F0aW9uIGZvbGxvd3MuIgp9CgpkZF93Z2V0KCkgewogICAgIyBOYXJyb3cgYWRhcHRlciBmb3IgdGhlIFVidW50dSBwYXRoOyB1bnN1cHBvcnRlZCBvcHRpb25zIGZhaWwgY2xvc2VkLgogICAgbG9jYWwgdXJsPScnIG91dHB1dD0tIHNwaWRlcj0wIGhlYWRlcnM9MAogICAgd2hpbGUgWyAiJCMiIC1ndCAwIF07IGRvCiAgICAgICAgY2FzZSAiJDEiIGluCiAgICAgICAgICAgIGh0dHBzOi8vKikgdXJsPSQxOyBzaGlmdCA7OwogICAgICAgICAgICAtTykgb3V0cHV0PSQyOyBzaGlmdCAyIDs7CiAgICAgICAgICAgIC1PLSkgb3V0cHV0PS07IHNoaWZ0IDs7CiAgICAgICAgICAgIC0tc3BpZGVyKSBzcGlkZXI9MTsgc2hpZnQgOzsKICAgICAgICAgICAgLVMpIGhlYWRlcnM9MTsgc2hpZnQgOzsKICAgICAgICAgICAgKikgZGRfZmFpbCAiVW5zdXBwb3J0ZWQgd2dldCBhcmd1bWVudDogJDEiIDs7CiAgICAgICAgZXNhYwogICAgZG9uZQogICAgWyAtbiAiJHVybCIgXSB8fCBkZF9mYWlsICdIVFRQUyBVUkwgcmVxdWlyZWQnCiAgICBpZiBbICIkc3BpZGVyIiA9IDEgXTsgdGhlbgogICAgICAgICMgUmV0YWluIEdOVSB3Z2V0J3Mgc3RkZXJyIGhlYWRlciBsYXlvdXQgZm9yIHVwc3RyZWFtIHNpemUgcGFyc2luZy4KICAgICAgICBkZF9odHRwcyAtLWhlYWQgIiR1cmwiIHwgc2VkICdzL14vICAvJyA+JjIKICAgIGVsaWYgWyAiJGhlYWRlcnMiID0gMSBdOyB0aGVuCiAgICAgICAgZGRfaHR0cHMgLS1kdW1wLWhlYWRlciAvZGV2L3N0ZGVyciAtLW91dHB1dCAiJG91dHB1dCIgIiR1cmwiCiAgICBlbHNlCiAgICAgICAgZGRfaHR0cHMgLS1vdXRwdXQgIiRvdXRwdXQiICIkdXJsIgogICAgZmkKfQoKZGRfdmVyaWZ5X21hbmlmZXN0KCkgewogICAgbG9jYWwgZGlyPSQxIG5hbWU9JDIgZXhwZWN0ZWQKICAgIG1rZGlyIC1wICIkZGlyL2dudXBnIgogICAgY2htb2QgNzAwICIkZGlyL2dudXBnIgogICAgZ3BndiAtLWhvbWVkaXIgIiRkaXIvZ251cGciIC0ta2V5cmluZyAiJEREX0JVTkRMRS91YnVudHUtY2xvdWRpbWFnZS1rZXlyaW5nLmdwZyIgXAogICAgICAgICIkZGlyL1NIQTI1NlNVTVMuZ3BnIiAiJGRpci9TSEEyNTZTVU1TIiB8fCBkZF9mYWlsICdVYnVudHUgc2lnbmF0dXJlIGludmFsaWQnCiAgICBleHBlY3RlZD0kKGF3ayAtdiBuPSIkbmFtZSIgJ2xlbmd0aCgkMSk9PTY0ICYmICgkMj09biB8fCAkMj09Iioibikge3ByaW50ICQxfScgIiRkaXIvU0hBMjU2U1VNUyIpCiAgICBjYXNlICIkZXhwZWN0ZWQiIGluICcnfCpbIWEtZjAtOV0qKSBkZF9mYWlsICdNaXNzaW5nIG9yIGFtYmlndW91cyBVYnVudHUgaW1hZ2UgaGFzaCcgOzsgZXNhYwogICAgWyAiJHsjZXhwZWN0ZWR9IiA9IDY0IF0gfHwgZGRfZmFpbCAnRHVwbGljYXRlIFVidW50dSBpbWFnZSBoYXNoJwogICAgcHJpbnRmICclc1xuJyAiJGV4cGVjdGVkIgp9CgpkZF9jaGVja19tZW1vcnkoKSB7CiAgICAjIFJlc2VydmUgMSBHaUIgd29ya2luZyBtZW1vcnkgcGx1cyAxIEdpQiBmb3IgQVBUIGNhY2hlL292ZXJsYXkuCiAgICBsb2NhbCBieXRlcz0kMSBhdmFpbGFibGU9JDIKICAgIFsgIiRhdmFpbGFibGUiIC1nZSAiJCgoYnl0ZXMgKyAyMTQ3NDgzNjQ4KSkiIF0gfHwgZGRfZmFpbCAnSW5zdWZmaWNpZW50IFJBTSBmb3IgaW1hZ2UsIHBhY2thZ2UgY2FjaGUgYW5kIHdvcmtpbmcgcmVzZXJ2ZTsgb3JpZ2luYWwgZGlzayBoYXMgbm90IGJlZW4gZXJhc2VkJwp9CgpkZF9kaXNrX2NhY2hlKCkgeyBbICIke0REX0NBQ0hFX01PREU6LXJhbX0iID0gZGlzayBdOyB9CgpkZF9jaGVja19taW5pbXVtX3JhbSgpIHsKICAgIFsgIiQxIiAtZ2UgNDY5NzYyMDQ4IF0gfHwgZGRfZmFpbCAnQXQgbGVhc3Qgbm9taW5hbCA1MTIgTWlCIFJBTSAoNDQ4IE1pQiBNZW1Ub3RhbCkgaXMgcmVxdWlyZWQnCn0KCmRkX2Rpc2tfY2FjaGVfYnl0ZXMoKSB7CiAgICBsb2NhbCBzaXplPSQoKCQxICsgNDI5NDk2NzI5NikpCiAgICBbICIkc2l6ZSIgLWdlIDY0NDI0NTA5NDQgXSB8fCBzaXplPTY0NDI0NTA5NDQKICAgIGVjaG8gIiQoKCAoc2l6ZSArIDEwNDg1NzUpIC8gMTA0ODU3NiAqIDEwNDg1NzYgKSkiCn0KCmRkX3JlcXVpcmVfcGFydGl0aW9uKCkgewogICAgIyBSZWNoZWNrIGFmdGVyIGRvd25sb2FkcyBhbmQgaW1tZWRpYXRlbHkgYmVmb3JlIHRoZSBkZXN0cnVjdGl2ZSBib3VuZGFyeS4KICAgIGRkX3ZlcmlmeV9kaXNrX2lkZW50aXR5ICIvZGV2LyR4ZGEiCiAgICBpZiBkZF9kaXNrX2NhY2hlOyB0aGVuCiAgICAgICAgWyAiJHtERF9QQVJUSVRJT05fUkVBRFk6LTB9IiA9IDEgXSB8fCBkZF9mYWlsICdEaXNrIHBhcnRpdGlvbmluZyBub3QgYXV0aG9yaXplZCBieSBtZXRhZGF0YSBwcmVmbGlnaHQnCiAgICAgICAgIyBBIHByb2Nlc3MtbG9jYWwgb25lLXNob3QgZ2F0ZSwgbmV2ZXIgYSBwZXJzaXN0ZW50IG1hcmtlciB0byBieXBhc3MgY2hlY2tzLgogICAgICAgIEREX1BBUlRJVElPTl9SRUFEWT0wCiAgICBlbHNlCiAgICAgICAgZGRfcmVxdWlyZV92ZXJpZmllZAogICAgZmkKICAgIGlmIFsgIiR7RERfSU5TVEFMTF9BQ1RJVkU6LTB9IiA9IDEgXTsgdGhlbgogICAgICAgIFsgISAtZSAiJEREX0lOU1RBTExfU1RBVEUvZGVzdHJ1Y3RpdmUiIF0gfHwgZGRfZmFpbCAnUmVwZWF0ZWQgcGFydGl0aW9uaW5nIHJlZnVzZWQnCiAgICAgICAgIyBSZWNvcmQgYmVmb3JlIHRoZSBmaXJzdCBkZXN0cnVjdGl2ZSBjb21tYW5kLCBpbmNsdWRpbmcgcGFydGlhbCBmYWlsdXJlLgogICAgICAgICh1bWFzayAwNzc7IHNldCAtQzsgcHJpbnRmICclc1xuJyAiJHt4ZGE6LXVua25vd259IiA+ICIkRERfSU5TVEFMTF9TVEFURS9kZXN0cnVjdGl2ZSIpIHx8IGRkX2ZhaWwgJ0Nhbm5vdCByZWNvcmQgcGFydGl0aW9uIGJvdW5kYXJ5JwogICAgICAgIGRkX2luc3RhbGxfc3RhZ2UgcGFydGl0aW9uaW5nCiAgICBmaQp9CgpkZF9wcmVwYXJlX2luc3RhbGwoKSB7CiAgICBkZF9wcmVmbGlnaHQKICAgIGlmICEgZGRfZGlza19jYWNoZTsgdGhlbiBjcmVhdGVfcGFydDsgZmkKICAgIGRvd25sb2FkX3Fjb3cKfQoKZGRfcHJlcGFyZV9kaXNrX2NhY2hlKCkgewogICAgbG9jYWwgYnl0ZXM9JDEgdG90YWw9JDIgY2FwYWNpdHkgcmVzZXJ2ZQogICAgZGRfY2hlY2tfbWluaW11bV9yYW0gIiR0b3RhbCIKICAgIGNhcGFjaXR5PSQoYmxvY2tkZXYgLS1nZXRzaXplNjQgIi9kZXYvJHhkYSIpCiAgICByZXNlcnZlPSQoZGRfZGlza19jYWNoZV9ieXRlcyAiJGJ5dGVzIikKICAgIGlmIFsgIiRjYXBhY2l0eSIgLWx0IDE3MTc5ODY5MTg0IF0gfHwgWyAiJGNhcGFjaXR5IiAtbHQgIiQoKHJlc2VydmUgKyA4NTg5OTM0NTkyKSkiIF07IHRoZW4KICAgICAgICBkZF9mYWlsICdEaXNrIG1vZGUgcmVxdWlyZXMgYXQgbGVhc3QgMTYgR2lCIGFuZCA4IEdpQiBvdXRzaWRlIHRoZSBjYWNoZSBwYXJ0aXRpb24nCiAgICBmaQogICAgIyBBdXRoZW50aWNhdGUgdGhlIGV4YWN0IG1hbmlmZXN0IGFuZCB2ZXJpZnkgdGhlIEhUVFBTIGVuZHBvaW50IGJlZm9yZQogICAgIyByZXBhcnRpdGlvbmluZy4gRnVsbCBwYXlsb2FkIHZlcmlmaWNhdGlvbiBmb2xsb3dzIG9uIHRoZSBuZXcgZGlzayBjYWNoZS4KICAgIGRkX3ZlcmlmeV9tYW5pZmVzdCAiJEREX0JVTkRMRSIgIiR7aW1nIyMqL30iID4vZGV2L251bGwgfHwgZXhpdCAxCiAgICBkZF9odHRwcyAtLWhlYWQgLS1vdXRwdXQgL2Rldi9udWxsICIkaW1nIiB8fCBkZF9mYWlsICdJbWFnZSBlbmRwb2ludCB1bmF2YWlsYWJsZTsgZGlzayBub3QgZXJhc2VkJwogICAgZWNobyAnRElTSyBDQUNIRTogcmVwYXJ0aXRpb25pbmcgbm93OyBsYXRlciBkb3dubG9hZCBvciB2YWxpZGF0aW9uIGZhaWx1cmVzIGNhbm5vdCByZXN0b3JlIHRoZSBvbGQgc3lzdGVtLicKICAgIEREX1BBUlRJVElPTl9SRUFEWT0xCiAgICBjcmVhdGVfcGFydAogICAgZGRfaW5zdGFsbF9zdGFnZSBjYWNoZS1zZXR1cAogICAgbWtkaXIgLXAgL2luc3RhbGxlcgogICAgbW91bnQgIiRkZXZfaW5zdGFsbGVyIiAvaW5zdGFsbGVyCiAgICBjaG1vZCA3MDAgL2luc3RhbGxlcgogICAgIyBBIHJlYWwgZGlzay1iYWNrZWQgc3dhcCBmaWxlLCBuZXZlciBvbiB0bXBmcyBvciB0aGUgb2xkIGVyYXNlZCBsYXlvdXQuCiAgICBkZCBpZj0vZGV2L3plcm8gb2Y9L2luc3RhbGxlci9zd2FwZmlsZSBicz0xMDQ4NTc2IGNvdW50PTIwNDggMj4vZGV2L251bGwgfHwgZGRfZmFpbCAnQ2Fubm90IGFsbG9jYXRlIGluc3RhbGxlciBzd2FwJwogICAgY2htb2QgNjAwIC9pbnN0YWxsZXIvc3dhcGZpbGUKICAgIG1rc3dhcCAvaW5zdGFsbGVyL3N3YXBmaWxlCiAgICBzd2Fwb24gL2luc3RhbGxlci9zd2FwZmlsZSB8fCBkZF9mYWlsICdDYW5ub3QgYWN0aXZhdGUgaW5zdGFsbGVyIHN3YXAnCiAgICBERF9DQUNIRT0vaW5zdGFsbGVyL2RkLWNhY2hlCiAgICBleHBvcnQgRERfUEFDS0FHRV9TT1VSQ0U9JEREX0NBQ0hFL3BhY2thZ2VzCiAgICBta2RpciAtcCAiJEREX0NBQ0hFIgogICAgZXhwb3J0IERQS0dfREVCX1RIUkVBRFNfTUFYPTEKfQoKZGRfcmVsZWFzZV9pbnN0YWxsZXIoKSB7CiAgICBpZiBkZF9kaXNrX2NhY2hlOyB0aGVuIHN5bmM7IGVsc2UgdW1vdW50IC9pbnN0YWxsZXIvOyBmaQp9CgpkZF9maW5pc2hfcGFydGl0aW9uX2xheW91dCgpIHsKICAgIGlmIGRkX2Rpc2tfY2FjaGU7IHRoZW4KICAgICAgICBlY2hvICdSZXRhaW5pbmcgaW5zdGFsbGVyIHBhcnRpdGlvbiBmb3IgdGFyZ2V0IHN3YXAgYW5kIHNjcmF0Y2ggc3BhY2UuJwogICAgZWxzZQogICAgICAgIHBhcnRlZCAiL2Rldi8keGRhIiAtcyAtLSBybSAzCiAgICAgICAgdXBkYXRlX3BhcnQKICAgICAgICByZXNpemVfYWZ0ZXJfaW5zdGFsbF9jbG91ZF9pbWFnZQogICAgZmkKfQoKZGRfZmluYWxpemVfZGlza19jYWNoZSgpIHsKICAgIGRkX2Rpc2tfY2FjaGUgfHwgcmV0dXJuIDAKICAgIGxvY2FsIHJvb3Q9JDEgdXVpZCBzb3VyY2UKICAgIGlmIFsgIiRERF9DQUNIRSIgIT0gL2luc3RhbGxlci9kZC1jYWNoZSBdIHx8IFsgLUwgIiRERF9DQUNIRSIgXTsgdGhlbiBkZF9mYWlsICdVbmV4cGVjdGVkIGRpc2sgY2FjaGUgcGF0aCc7IGZpCiAgICBzb3VyY2U9JChmaW5kbW50IC1uIC1vIFNPVVJDRSAtLXRhcmdldCAvaW5zdGFsbGVyKQogICAgWyAiJChyZWFkbGluayAtZiAiJHNvdXJjZSIpIiA9ICIkKHJlYWRsaW5rIC1mICIkZGV2X2luc3RhbGxlciIpIiBdIHx8IGRkX2ZhaWwgJ0luc3RhbGxlciBtb3VudCBjaGFuZ2VkJwogICAgaWYgWyAhIC1mIC9pbnN0YWxsZXIvc3dhcGZpbGUgXSB8fCBbIC1MIC9pbnN0YWxsZXIvc3dhcGZpbGUgXTsgdGhlbiBkZF9mYWlsICdJbnN0YWxsZXIgc3dhcCBtaXNzaW5nJzsgZmkKICAgIGdyZXAgLXEgJ14vaW5zdGFsbGVyL3N3YXBmaWxlICcgL3Byb2Mvc3dhcHMgfHwgZGRfZmFpbCAnSW5zdGFsbGVyIHN3YXAgaXMgbm90IGFjdGl2ZScKICAgIHV1aWQ9JChibGtpZCAtcyBVVUlEIC1vIHZhbHVlICIkZGV2X2luc3RhbGxlciIpCiAgICBjYXNlICIkdXVpZCIgaW4gJyd8KlshYS1mQS1GMC05LV0qKSBkZF9mYWlsICdJbnZhbGlkIHNjcmF0Y2ggZmlsZXN5c3RlbSBVVUlEJyA7OyBlc2FjCiAgICBta2RpciAtcCAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvc2NyYXRjaCIKICAgIHByaW50ZiAnVVVJRD0lcyAvdmFyL2xpYi91YnVudHUtZGQvc2NyYXRjaCBleHQ0IGRlZmF1bHRzLG5vc3VpZCxub2RldiAwIDJcbicgIiR1dWlkIiA+PiAiJHJvb3QvZXRjL2ZzdGFiIgogICAgcHJpbnRmICcvdmFyL2xpYi91YnVudHUtZGQvc2NyYXRjaC9zd2FwZmlsZSBub25lIHN3YXAgc3cgMCAwXG4nID4+ICIkcm9vdC9ldGMvZnN0YWIiCiAgICBwcmludGYgJ2NhY2hlPWRpc2tcbnNjcmF0Y2hfdXVpZD0lc1xuc3dhcF9ieXRlcz0yMTQ3NDgzNjQ4XG4nICIkdXVpZCIgPiAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvc3RvcmFnZS1wb2xpY3kiCiAgICAjIFRoZSBOQkQgYW5kIHBhY2thZ2Ugb3ZlcmxheSBtdXN0IGJlIGRldGFjaGVkIGJlZm9yZSBmcmVlaW5nIHRoaXMgY2FjaGUuCiAgICBpZiBhd2sgJyQyID09ICIvaW5zdGFsbGVyL2RkLWNhY2hlIiB8fCBpbmRleCgkMiwgIi9pbnN0YWxsZXIvZGQtY2FjaGUvIikgPT0gMSB7Zm91bmQ9MX0gRU5EIHtleGl0ICFmb3VuZH0nIC9wcm9jL21vdW50czsgdGhlbgogICAgICAgIGRkX2ZhaWwgJ05lc3RlZCBjYWNoZSBtb3VudHMgcmVtYWluJwogICAgZmkKICAgIHJtIC1yZiAtLSAiJEREX0NBQ0hFIgogICAgc3luYwp9CgpkZF9jaGVja19saXZlX25pY3MoKSB7CiAgICBsb2NhbCBtYWMgZHJpdmVyIHBhdGggZm91bmQgYWN0dWFsCiAgICB3aGlsZSByZWFkIC1yIG1hYyBkcml2ZXI7IGRvCiAgICAgICAgWyAtbiAiJG1hYyIgXSB8fCBjb250aW51ZQogICAgICAgIGZvdW5kPTAKICAgICAgICBmb3IgcGF0aCBpbiAvc3lzL2NsYXNzL25ldC8qOyBkbwogICAgICAgICAgICBbIC1lICIkcGF0aC9kZXZpY2UiIF0gfHwgY29udGludWUKICAgICAgICAgICAgWyAiJChjYXQgIiRwYXRoL2FkZHJlc3MiKSIgPSAiJG1hYyIgXSB8fCBjb250aW51ZQogICAgICAgICAgICBmb3VuZD0xCiAgICAgICAgICAgIGFjdHVhbD0kKGJhc2VuYW1lICIkKHJlYWRsaW5rIC1mICIkcGF0aC9kZXZpY2UvZHJpdmVyL21vZHVsZSIpIikKICAgICAgICAgICAgWyAiJGFjdHVhbCIgPSAiJGRyaXZlciIgXSB8fCBkZF9mYWlsICJOSUMgJG1hYyByZXF1aXJlcyAkZHJpdmVyLCBpbnN0YWxsZXIgaGFzICRhY3R1YWwiCiAgICAgICAgZG9uZQogICAgICAgIFsgIiRmb3VuZCIgPSAxIF0gfHwgZGRfZmFpbCAiTklDICRtYWMgbm90IGF2YWlsYWJsZSBpbiBpbnN0YWxsZXIiCiAgICBkb25lIDwgIiRERF9CVU5ETEUvbmljcyIKICAgIGlmICEgaXAgLTQgcm91dGUgc2hvdyBkZWZhdWx0IHwgZ3JlcCAtcSAuICYmICEgaXAgLTYgcm91dGUgc2hvdyBkZWZhdWx0IHwgZ3JlcCAtcSAuOyB0aGVuCiAgICAgICAgZGRfZmFpbCAnSW5zdGFsbGVyIGhhcyBubyBkZWZhdWx0IHJvdXRlJwogICAgZmkKfQoKZGRfY2hlY2tfa2VybmVsX2RyaXZlcnMoKSB7CiAgICBsb2NhbCByb290PSQxIGtlcm5lbD0kMiBkcml2ZXIgZmlsZW5hbWUKICAgIHdoaWxlIHJlYWQgLXIgZHJpdmVyOyBkbwogICAgICAgIFsgLW4gIiRkcml2ZXIiIF0gfHwgY29udGludWUKICAgICAgICBmaWxlbmFtZT0kKGNocm9vdCAiJHJvb3QiIG1vZGluZm8gLWsgIiRrZXJuZWwiIC1GIGZpbGVuYW1lICIkZHJpdmVyIikgfHwgZGRfZmFpbCAiS2VybmVsICRrZXJuZWwgbWlzc2luZyAkZHJpdmVyIgogICAgICAgIFsgLW4gIiRmaWxlbmFtZSIgXSB8fCBkZF9mYWlsICJFbXB0eSBtb2R1bGUgcmVzdWx0OiAkZHJpdmVyIgogICAgZG9uZSA8ICIkRERfQlVORExFL2RyaXZlcnMiCn0KCmdldF91YnVudHVfa2VybmVsX2ZsYXZvcigpIHsKICAgIGNhc2UgIiQoY2F0ICIkRERfQlVORExFL2Nsb3VkIikiIGluCiAgICAgICAgZ2NwKSBlY2hvIGdjcCA7OwogICAgICAgIGF3c3xsaWdodHNhaWwpIGVjaG8gYXdzIDs7CiAgICAgICAgb2NpKSBlY2hvIG9yYWNsZSA7OwogICAgICAgICopIGRkX3Vwc3RyZWFtX2tlcm5lbF9mbGF2b3IgOzsKICAgIGVzYWMKfQoKZGRfY2hlY2tfaW1hZ2VfZHJpdmVycygpIHsKICAgIGxvY2FsIHJvb3Q9JDEga2VybmVsPSQyIGRyaXZlciBjbG91ZAogICAgY2xvdWQ9JChjYXQgIiRERF9CVU5ETEUvY2xvdWQiKQogICAgd2hpbGUgcmVhZCAtciBkcml2ZXI7IGRvCiAgICAgICAgaWYgY2hyb290ICIkcm9vdCIgbW9kaW5mbyAtayAiJGtlcm5lbCIgIiRkcml2ZXIiID4vZGV2L251bGwgMj4mMTsgdGhlbiBjb250aW51ZTsgZmkKICAgICAgICBjYXNlICIkY2xvdWQiIGluCiAgICAgICAgICAgIGdjcHxhd3N8bGlnaHRzYWlsfG9jaSkKICAgICAgICAgICAgICAgICMgVGhlIGdlbmVyaWMgY2xvdWQgaW1hZ2UgZG9lcyBub3Qgc2hpcCBldmVyeSBjbG91ZCBkcml2ZXIKICAgICAgICAgICAgICAgICMgKG5vdGFibHkgZ3ZlKS4gbW9kaWZ5X3VidW50dSBpbnN0YWxscyB0aGUgc2VsZWN0ZWQgY2xvdWQKICAgICAgICAgICAgICAgICMga2VybmVsOyBkZF9maW5hbGl6ZV90YXJnZXQgdGhlbiByZXF1aXJlcyBhbGwgaXRzIGRyaXZlcnMuCiAgICAgICAgICAgICAgICBlY2hvICJJbWFnZSBrZXJuZWwgbGFja3MgJGRyaXZlcjsgc2VsZWN0ZWQgY2xvdWQga2VybmVsIG11c3QgcHJvdmlkZSBpdCBiZWZvcmUgcmVib290LiIgPiYyIDs7CiAgICAgICAgICAgICopIGRkX2ZhaWwgIkltYWdlIGtlcm5lbCAka2VybmVsIGxhY2tzICRkcml2ZXIgYW5kIG5vIGNsb3VkIGtlcm5lbCBpcyBzZWxlY3RlZCIgOzsKICAgICAgICBlc2FjCiAgICBkb25lIDwgIiRERF9CVU5ETEUvZHJpdmVycyIKfQoKZGRfcHJlZmxpZ2h0X2ltYWdlKCkgKAogICAgbG9jYWwgcGFydCByb290cGFydD0nJyBrZXJuZWwKICAgIG1vZHByb2JlIG5iZCBuYmRzX21heD0xIG1heF9wYXJ0PTE2CiAgICBbICEgLWUgL3N5cy9ibG9jay9uYmQwL3BpZCBdIHx8IGRkX2ZhaWwgJ25iZDAgaXMgYWxyZWFkeSBpbiB1c2UnCiAgICB0cmFwICd1bW91bnQgIiRERF9DQUNIRS9yb290IiAyPi9kZXYvbnVsbCB8fCB0cnVlOyBxZW11LW5iZCAtLWRpc2Nvbm5lY3QgL2Rldi9uYmQwID4vZGV2L251bGwgMj4mMSB8fCB0cnVlJyBFWElUCiAgICBxZW11LW5iZCAtLXJlYWQtb25seSAtLWZvcm1hdD1xY293MiAtLWNvbm5lY3Q9L2Rldi9uYmQwICIkRERfQ0FDSEUvaW1hZ2UuaW1nIgogICAgbG9jYWwgY291bnQ9MAogICAgd2hpbGUgWyAhIC1iIC9kZXYvbmJkMHAxIF07IGRvCiAgICAgICAgY291bnQ9JCgoY291bnQgKyAxKSk7IFsgIiRjb3VudCIgLWxlIDMwIF0gfHwgZGRfZmFpbCAnSW1hZ2UgcGFydGl0aW9uIGRpc2NvdmVyeSB0aW1lZCBvdXQnCiAgICAgICAgc2xlZXAgMQogICAgZG9uZQogICAgbWtkaXIgLXAgIiRERF9DQUNIRS9yb290IgogICAgZm9yIHBhcnQgaW4gL2Rldi9uYmQwcCo7IGRvCiAgICAgICAgWyAiJChibGtpZCAtcyBUWVBFIC1vIHZhbHVlICIkcGFydCIpIiA9IGV4dDQgXSB8fCBjb250aW51ZQogICAgICAgIGlmIG1vdW50IC1vIHJvLG5vbG9hZCAiJHBhcnQiICIkRERfQ0FDSEUvcm9vdCI7IHRoZW4KICAgICAgICAgICAgaWYgWyAtZiAiJEREX0NBQ0hFL3Jvb3QvZXRjL29zLXJlbGVhc2UiIF07IHRoZW4gcm9vdHBhcnQ9JHBhcnQ7IGJyZWFrOyBmaQogICAgICAgICAgICB1bW91bnQgIiRERF9DQUNIRS9yb290IgogICAgICAgIGZpCiAgICBkb25lCiAgICBbIC1uICIkcm9vdHBhcnQiIF0gfHwgZGRfZmFpbCAnTm8gVWJ1bnR1IHJvb3QgZmlsZXN5c3RlbSBpbiBzaWduZWQgaW1hZ2UnCiAgICBncmVwIC1xeCAnSUQ9dWJ1bnR1JyAiJEREX0NBQ0hFL3Jvb3QvZXRjL29zLXJlbGVhc2UiIHx8IGRkX2ZhaWwgJ0ltYWdlIGlzIG5vdCBVYnVudHUnCiAgICBncmVwIC1xeCAiVkVSU0lPTl9JRD1cIiRyZWxlYXNldmVyXCIiICIkRERfQ0FDSEUvcm9vdC9ldGMvb3MtcmVsZWFzZSIgfHwgZGRfZmFpbCAnSW1hZ2UgdmVyc2lvbiBtaXNtYXRjaCcKICAgIGxvY2FsIGtlcm5lbHM9MAogICAgZm9yIGtlcm5lbCBpbiAiJEREX0NBQ0hFL3Jvb3QiL2xpYi9tb2R1bGVzLyo7IGRvCiAgICAgICAgWyAtZCAiJGtlcm5lbCIgXSB8fCBjb250aW51ZQogICAgICAgIGRkX2NoZWNrX2ltYWdlX2RyaXZlcnMgIiRERF9DQUNIRS9yb290IiAiJHtrZXJuZWwjIyovfSIKICAgICAgICBrZXJuZWxzPSQoKGtlcm5lbHMgKyAxKSkKICAgIGRvbmUKICAgIFsgIiRrZXJuZWxzIiAtZ3QgMCBdIHx8IGRkX2ZhaWwgJ0ltYWdlIGNvbnRhaW5zIG5vIGtlcm5lbCBtb2R1bGVzJwogICAgZGRfY2FjaGVfcGFja2FnZXMgIiRERF9DQUNIRS9yb290IgogICAgdW1vdW50ICIkRERfQ0FDSEUvcm9vdCIKICAgIHFlbXUtbmJkIC0tZGlzY29ubmVjdCAvZGV2L25iZDAKICAgIHRyYXAgLSBFWElUCikKCmRkX3ByZWZsaWdodCgpIHsKICAgIEREX0lNQUdFX1ZFUklGSUVEPTAKICAgIEREX1BBUlRJVElPTl9SRUFEWT0wCiAgICBERF9DQUNIRV9NT0RFPSQoY2F0ICIkRERfQlVORExFL2NhY2hlLW1vZGUiKQogICAgY2FzZSAiJEREX0NBQ0hFX01PREUiIGluIHJhbXxkaXNrKSA7OyAqKSBkZF9mYWlsICdJbnZhbGlkIGNhY2hlIG1vZGUnIDs7IGVzYWMKICAgIFsgIiRkaXN0cm86JHJlbGVhc2V2ZXI6JGltZ190eXBlIiA9ICJ1YnVudHU6MjQuMDQ6cWVtdSIgXSB8fAogICAgICAgIFsgIiRkaXN0cm86JHJlbGVhc2V2ZXI6JGltZ190eXBlIiA9ICJ1YnVudHU6MjYuMDQ6cWVtdSIgXSB8fCBkZF9mYWlsICdVbnN1cHBvcnRlZCBpbnN0YWxsYXRpb24gcGF0aCcKICAgIFsgIiRpbWciID0gIiQoY2F0ICIkRERfQlVORExFL2ltYWdlLXVybCIpIiBdIHx8IGRkX2ZhaWwgJ0ltYWdlIFVSTCBjaGFuZ2VkIGJldHdlZW4gc3RhZ2VzJwogICAgZGRfdmVyaWZ5X2Rpc2tfaWRlbnRpdHkgIi9kZXYvJHhkYSIKICAgICMgR2V0IGFsbCB0b29scyBmb3IgdmVyaWZpY2F0aW9uIGFuZCBwYXJ0aXRpb25pbmcgYmVmb3JlIGFsbG93aW5nIGRpc2sgd3JpdGVzLgogICAgYXBrIGFkZCBjdXJsIGNhLWNlcnRpZmljYXRlcyBnbnVwZyBxZW11LWltZyBqcSB1dGlsLWxpbnV4IHBhcnRlZCBlMmZzcHJvZ3MgZG9zZnN0b29scwogICAgZGRfY2hlY2tfbGl2ZV9uaWNzCiAgICBzd2Fwb2ZmIC1hCiAgICBERF9DQUNIRT0ke0REX0NBQ0hFOi0vZGQtaW1hZ2UtY2FjaGV9CiAgICBta2RpciAtcCAiJEREX0NBQ0hFIgogICAgaWYgbW91bnRwb2ludCAtcSAiJEREX0NBQ0hFIjsgdGhlbiB1bW91bnQgIiRERF9DQUNIRSI7IGZpCiAgICBsb2NhbCBieXRlcyBhdmFpbGFibGUgZGlnZXN0IHZpcnR1YWxfc2l6ZSB0b3RhbAogICAgYnl0ZXM9JChjYXQgIiRERF9CVU5ETEUvaW1hZ2UtYnl0ZXMiKQogICAgYXZhaWxhYmxlPSQoYXdrICcvTWVtQXZhaWxhYmxlOi8ge3ByaW50ZiAiJS4wZiIsICQyKjEwMjR9JyAvcHJvYy9tZW1pbmZvKQogICAgdG90YWw9JChhd2sgJy9NZW1Ub3RhbDovIHtwcmludGYgIiUuMGYiLCAkMioxMDI0fScgL3Byb2MvbWVtaW5mbykKICAgIGlmIGRkX2Rpc2tfY2FjaGU7IHRoZW4KICAgICAgICBkZF9wcmVwYXJlX2Rpc2tfY2FjaGUgIiRieXRlcyIgIiR0b3RhbCIKICAgIGVsc2UKICAgICAgICBkZF9jaGVja19tZW1vcnkgIiRieXRlcyIgIiRhdmFpbGFibGUiCiAgICAgICAgbW91bnQgLXQgdG1wZnMgLW8gInNpemU9JCgoYnl0ZXMgKyAxMDczNzQxODI0KSksbW9kZT0wNzAwLG5vc3VpZCxub2RldiIgdG1wZnMgIiRERF9DQUNIRSIKICAgIGZpCiAgICBjcCAiJEREX0JVTkRMRS9TSEEyNTZTVU1TIiAiJEREX0JVTkRMRS9TSEEyNTZTVU1TLmdwZyIgIiRERF9DQUNIRS8iCiAgICBkaWdlc3Q9JChkZF92ZXJpZnlfbWFuaWZlc3QgIiRERF9DQUNIRSIgIiR7aW1nIyMqL30iKSB8fCBleGl0IDEKICAgIGRkX2luc3RhbGxfc3RhZ2UgaW1hZ2UtZG93bmxvYWQKICAgIGRkX2Rvd25sb2FkX2ltYWdlICIkaW1nIiAiJEREX0NBQ0hFL2ltYWdlLmltZy5wYXJ0IiAiJGJ5dGVzIgogICAgZGRfaW5zdGFsbF9zdGFnZSBpbWFnZS12YWxpZGF0aW9uCiAgICBbICIkKHN0YXQgLWMgJXMgIiRERF9DQUNIRS9pbWFnZS5pbWcucGFydCIpIiA9ICIkYnl0ZXMiIF0gfHwgZGRfZmFpbCAnSW1hZ2Ugc2l6ZSBjaGFuZ2VkOyBwcmVwYXJlIGluc3RhbGxhdGlvbiBhZ2FpbicKICAgIHByaW50ZiAnJXMgICVzXG4nICIkZGlnZXN0IiAiJEREX0NBQ0hFL2ltYWdlLmltZy5wYXJ0IiB8IHNoYTI1NnN1bSAtYyAtIHx8IGRkX2ZhaWwgJ1VidW50dSBpbWFnZSBjaGVja3N1bSBtaXNtYXRjaCcKICAgIG12ICIkRERfQ0FDSEUvaW1hZ2UuaW1nLnBhcnQiICIkRERfQ0FDSEUvaW1hZ2UuaW1nIgogICAgcWVtdS1pbWcgaW5mbyAtLW91dHB1dD1qc29uICIkRERfQ0FDSEUvaW1hZ2UuaW1nIiA+ICIkRERfQ0FDSEUvaW5mby5qc29uIgogICAganEgLWUgJy5mb3JtYXQgPT0gInFjb3cyIiBhbmQgKGhhcygiYmFja2luZy1maWxlbmFtZSIpIHwgbm90KSBhbmQgKGhhcygiZGF0YS1maWxlIikgfCBub3QpIGFuZCAoKC5bImZvcm1hdC1zcGVjaWZpYyJdLmRhdGEgLy8ge30gfCBoYXMoImRhdGEtZmlsZSIpKSB8IG5vdCknICIkRERfQ0FDSEUvaW5mby5qc29uIiA+L2Rldi9udWxsIHx8IGRkX2ZhaWwgJ1Vuc3VwcG9ydGVkIGltYWdlIGZvcm1hdCBvciBleHRlcm5hbCBiYWNraW5nIGZpbGUnCiAgICBxZW11LWltZyBjaGVjayAtZiBxY293MiAiJEREX0NBQ0hFL2ltYWdlLmltZyIKICAgIHZpcnR1YWxfc2l6ZT0kKGpxIC1lciAnLlsidmlydHVhbC1zaXplIl0gfCBudW1iZXJzJyAiJEREX0NBQ0hFL2luZm8uanNvbiIpCiAgICBpZiBkZF9kaXNrX2NhY2hlOyB0aGVuCiAgICAgICAgWyAiJChibG9ja2RldiAtLWdldHNpemU2NCAiJGRldl9vcyIpIiAtZ2UgIiQoKHZpcnR1YWxfc2l6ZSArIDEwNzM3NDE4MjQpKSIgXSB8fCBkZF9mYWlsICdUYXJnZXQgcm9vdCBwYXJ0aXRpb24gdG9vIHNtYWxsJwogICAgZmkKICAgIFsgIiQoYmxvY2tkZXYgLS1nZXRzaXplNjQgIi9kZXYvJHhkYSIpIiAtZ2UgIiQoKHZpcnR1YWxfc2l6ZSArIGJ5dGVzICsgMjY4NDM1NDU2KSkiIF0gfHwgZGRfZmFpbCAnRGlzayB0b28gc21hbGwgZm9yIGltYWdlIGFuZCBpbnN0YWxsZXIgcGFydGl0aW9uJwogICAgZGRfaW5zdGFsbF9zdGFnZSBpbWFnZS1hbmQtcGFja2FnZS1wcmVmbGlnaHQKICAgIGRkX3ByZWZsaWdodF9pbWFnZQogICAgZGRfdmVyaWZ5X3BhY2thZ2VfY2FjaGUgIiRERF9DQUNIRS9wYWNrYWdlcyIKICAgIGxvY2FsIHBhY2thZ2VfYnl0ZXMKICAgIHBhY2thZ2VfYnl0ZXM9JChkdSAtc2sgIiRERF9DQUNIRS9wYWNrYWdlcyIgfCBhd2sgJ3twcmludCAkMSAqIDEwMjR9JykKICAgIFsgIiQoYmxvY2tkZXYgLS1nZXRzaXplNjQgIi9kZXYvJHhkYSIpIiAtZ2UgIiQoKHZpcnR1YWxfc2l6ZSArIGJ5dGVzICsgcGFja2FnZV9ieXRlcyAqIDIgKyAyNjg0MzU0NTYpKSIgXSB8fCBkZF9mYWlsICdEaXNrIHRvbyBzbWFsbCBmb3IgaW1hZ2UgYW5kIHBhY2thZ2UgY2FjaGUnCiAgICAjIFRoZSBnYXRlIGlzIHByb2Nlc3MtbG9jYWw7IGEgcmV0cnkgbXVzdCByZS1ydW4gYWxsIGNoZWNrcy4KICAgIEREX0lNQUdFX1ZFUklGSUVEPTEKICAgIGVjaG8gIlVidW50dSBzaWduYXR1cmUsIGltYWdlLCBkcml2ZXJzIGFuZCBwYWNrYWdlIHZlcmlmaWNhdGlvbiBwYXNzZWQgKGNhY2hlPSRERF9DQUNIRV9NT0RFKS4iCn0KCmRkX3JlcXVpcmVfdmVyaWZpZWQoKSB7CiAgICBpZiBbICIke0REX0lNQUdFX1ZFUklGSUVEOi0wfSIgIT0gMSBdIHx8IFsgISAtZiAiJEREX0NBQ0hFL2ltYWdlLmltZyIgXTsgdGhlbgogICAgICAgIGRkX2ZhaWwgJ0Rpc2sgd3JpdGUgcmVmdXNlZDogaW1hZ2Ugbm90IHZlcmlmaWVkJwogICAgZmkKICAgIGRkX3ZlcmlmeV9wYWNrYWdlX2NhY2hlICIkRERfQ0FDSEUvcGFja2FnZXMiCn0KCmRvd25sb2FkX3Fjb3coKSB7CiAgICBkZF9yZXF1aXJlX3ZlcmlmaWVkCiAgICBkZF9pbnN0YWxsX3N0YWdlIGltYWdlLWNvcHkKICAgIGlmIGRkX2Rpc2tfY2FjaGU7IHRoZW4KICAgICAgICBxY293X2ZpbGU9JEREX0NBQ0hFL2ltYWdlLmltZwogICAgICAgIHJldHVybgogICAgZmkKICAgIG1rZGlyIC1wIC9pbnN0YWxsZXIKICAgIG1vdW50ICIvZGV2LyQoeGRhIGluc3RhbGxlcikiIC9pbnN0YWxsZXIKICAgIHFjb3dfZmlsZT0vaW5zdGFsbGVyL2Nsb3VkX2ltYWdlLnFjb3cyCiAgICBjcCAiJEREX0NBQ0hFL2ltYWdlLmltZyIgIiRxY293X2ZpbGUiCiAgICBjbXAgIiRERF9DQUNIRS9pbWFnZS5pbWciICIkcWNvd19maWxlIiB8fCBkZF9mYWlsICdJbnN0YWxsZXIgZGlzayBjb3B5IGRpZmZlcnMgZnJvbSB2ZXJpZmllZCBpbWFnZScKICAgIGNwIC1hICIkRERfQ0FDSEUvcGFja2FnZXMiIC9pbnN0YWxsZXIvZGQtcGFja2FnZXMKICAgIGRkX3ZlcmlmeV9wYWNrYWdlX2NhY2hlIC9pbnN0YWxsZXIvZGQtcGFja2FnZXMKICAgIHVtb3VudCAiJEREX0NBQ0hFIgp9CgpnZXRfY2xvdWRfaW1hZ2VfcGFydF9zaXplKCkgewogICAgaWYgZGRfZGlza19jYWNoZTsgdGhlbgogICAgICAgIGVjaG8gIiQoKCQoZGRfZGlza19jYWNoZV9ieXRlcyAiJChjYXQgIiRERF9CVU5ETEUvaW1hZ2UtYnl0ZXMiKSIpIC8gMTA0ODU3NikpTWlCIgogICAgICAgIHJldHVybgogICAgZmkKICAgIGxvY2FsIHBhY2thZ2VfYnl0ZXMKICAgIHBhY2thZ2VfYnl0ZXM9JChkdSAtc2sgIiRERF9DQUNIRS9wYWNrYWdlcyIgfCBhd2sgJ3twcmludCAkMSAqIDEwMjR9JykKICAgIGVjaG8gIiQoZ2V0X3BhcnRfc2l6ZV9tYl9mb3JfZmlsZV9zaXplX2IgIiQoKCQoY2F0ICIkRERfQlVORExFL2ltYWdlLWJ5dGVzIikgKyBwYWNrYWdlX2J5dGVzKSkiKU1pQiIKfQoKZGRfY2xvdWRfaW5pdF9wb2xpY3koKSB7CiAgICBsb2NhbCByb290PSQxIGNsb3VkIGRhdGFzb3VyY2UKICAgIGNsb3VkPSQoY2F0ICIkRERfQlVORExFL2Nsb3VkIikKICAgIGNhc2UgIiRjbG91ZCIgaW4gZ2NwKSBkYXRhc291cmNlPUdDRSA7OyBhd3N8bGlnaHRzYWlsKSBkYXRhc291cmNlPUVjMiA7OyBvY2kpIGRhdGFzb3VyY2U9T3JhY2xlIDs7ICopIGRhdGFzb3VyY2U9Tm9uZSA7OyBlc2FjCiAgICAjIExldCBjbG91ZC1pbml0IGlkZW50aWZ5IHRoZSBpbnN0YW5jZSwgYnV0IGtlZXAgaW5zdGFsbGVyLW93bmVkIG5ldHdvcmsgYW5kCiAgICAjIGNyZWRlbnRpYWxzLiBEbyBub3QgZXhlY3V0ZSBtZXRhZGF0YSB1c2VyLWRhdGEsIHZlbmRvciBzY3JpcHRzIG9yIGFnZW50cy4KICAgIG1rZGlyIC1wICIkcm9vdC9ldGMvY2xvdWQvY2xvdWQuY2ZnLmQiCiAgICBjYXQgPiAiJHJvb3QvZXRjL2Nsb3VkL2Nsb3VkLmNmZy5kLzk5LXp6LXVidW50dS1kZC5jZmciIDw8RU9GCmRhdGFzb3VyY2VfbGlzdDogWyAkZGF0YXNvdXJjZSwgTm9uZSBdCm5ldHdvcms6IHtjb25maWc6IGRpc2FibGVkfQpkaXNhYmxlX3Jvb3Q6IGZhbHNlCnVzZXJzOiBbXQphbGxvd191c2VyZGF0YTogZmFsc2UKY2xvdWRfaW5pdF9tb2R1bGVzOiBbc2VlZF9yYW5kb21dCmNsb3VkX2NvbmZpZ19tb2R1bGVzOiBbXQpjbG91ZF9maW5hbF9tb2R1bGVzOiBbXQpFT0YKICAgICMgR0NFIHByb2JlcyBtZXRhZGF0YSBkdXJpbmcgaW5pdC1sb2NhbCwgYmVmb3JlIHRoZSBETlMgcmVzb2x2ZXIgaXMgcmVhZHkuCiAgICAjIFRoZSBsaW5rLWxvY2FsIGVuZHBvaW50IGlzIHJlYWNoYWJsZSB1c2luZyB0aGUgdGVtcG9yYXJ5IERIQ1Agcm91dGUuCiAgICBpZiBbICIkY2xvdWQiID0gZ2NwIF07IHRoZW4KICAgICAgICBjYXQgPj4gIiRyb290L2V0Yy9jbG91ZC9jbG91ZC5jZmcuZC85OS16ei11YnVudHUtZGQuY2ZnIiA8PCdFT0YnCmRhdGFzb3VyY2U6CiAgR0NFOgogICAgbWV0YWRhdGFfdXJsOiBodHRwOi8vMTY5LjI1NC4xNjkuMjU0L2NvbXB1dGVNZXRhZGF0YS92MS8KRU9GCiAgICBmaQogICAgcm0gLWYgIiRyb290L2V0Yy9jbG91ZC9jbG91ZC1pbml0LmRpc2FibGVkIgogICAgbWtkaXIgLXAgIiRyb290L3Zhci9saWIvdWJ1bnR1LWRkIgogICAgcHJpbnRmICdjbG91ZD0lc1xubmV0d29yaz1pbnN0YWxsZXJcbmNyZWRlbnRpYWxzPWluc3RhbGxlclxubWV0YWRhdGFfc2NyaXB0cz1kaXNhYmxlZFxuJyAiJGNsb3VkIiA+ICIkcm9vdC92YXIvbGliL3VidW50dS1kZC9jbG91ZC1wb2xpY3kiCn0KCmRkX2ZpbmFsaXplX3RhcmdldCgpIHsKICAgIGxvY2FsIHJvb3Q9JDEga2VybmVsIGRyaXZlciBmaWxlbmFtZSBtb2R1bGVzIGNvdW50PTAKICAgIGRkX2Nsb3VkX2luaXRfcG9saWN5ICIkcm9vdCIKICAgICMgUmVxdWlyZWQgZHJpdmVycyBpbmNsdWRlIGRldGVjdGVkIE5JQ3MgYW5kIGFjdGl2ZSBzdG9yYWdlIGJ1cyBtb2R1bGVzLgogICAgbWtkaXIgLXAgIiRyb290L2V0Yy9pbml0cmFtZnMtdG9vbHMiCiAgICB0b3VjaCAiJHJvb3QvZXRjL2luaXRyYW1mcy10b29scy9tb2R1bGVzIgogICAgd2hpbGUgcmVhZCAtciBkcml2ZXI7IGRvCiAgICAgICAgZ3JlcCAtcXhGICIkZHJpdmVyIiAiJHJvb3QvZXRjL2luaXRyYW1mcy10b29scy9tb2R1bGVzIiB8fCBlY2hvICIkZHJpdmVyIiA+PiAiJHJvb3QvZXRjL2luaXRyYW1mcy10b29scy9tb2R1bGVzIgogICAgZG9uZSA8ICIkRERfQlVORExFL2RyaXZlcnMiCiAgICAjIFJlcXVpcmUgYSByZWFsIGluaXRyYW1mcyBib290LCBpbmNsdWRpbmcgb24gY2xvdWQgaW1hZ2VzIHVzaW5nIFBBUlRVVUlELgogICAgaWYgWyAtZiAiJHJvb3QvZXRjL2RlZmF1bHQvZ3J1Yi5kLzQwLWZvcmNlLXBhcnR1dWlkLmNmZyIgXTsgdGhlbgogICAgICAgIHNlZCAtaSAnL15HUlVCX0ZPUkNFX1BBUlRVVUlEPS9kJyAiJHJvb3QvZXRjL2RlZmF1bHQvZ3J1Yi5kLzQwLWZvcmNlLXBhcnR1dWlkLmNmZyIKICAgIGZpCiAgICBjaHJvb3QgIiRyb290IiB1cGRhdGUtaW5pdHJhbWZzIC11IC1rIGFsbAogICAgY2hyb290ICIkcm9vdCIgdXBkYXRlLWdydWIKICAgIGZvciBrZXJuZWwgaW4gIiRyb290Ii9ib290L3ZtbGludXotKjsgZG8KICAgICAgICBbIC1mICIka2VybmVsIiBdIHx8IGNvbnRpbnVlCiAgICAgICAga2VybmVsPSR7a2VybmVsIyMqL3ZtbGludXotfQogICAgICAgIGNvdW50PSQoKGNvdW50ICsgMSkpCiAgICAgICAgZGRfY2hlY2tfa2VybmVsX2RyaXZlcnMgIiRyb290IiAiJGtlcm5lbCIKICAgICAgICBbIC1zICIkcm9vdC9ib290L2luaXRyZC5pbWctJGtlcm5lbCIgXSB8fCBkZF9mYWlsICJNaXNzaW5nIGluaXRyYW1mcyBmb3IgJGtlcm5lbCIKICAgICAgICBtb2R1bGVzPSQoY2hyb290ICIkcm9vdCIgbHNpbml0cmFtZnMgIi9ib290L2luaXRyZC5pbWctJGtlcm5lbCIpIHx8IGRkX2ZhaWwgJ0Nhbm5vdCBpbnNwZWN0IGluaXRyYW1mcycKICAgICAgICB3aGlsZSByZWFkIC1yIGRyaXZlcjsgZG8KICAgICAgICAgICAgZmlsZW5hbWU9JChjaHJvb3QgIiRyb290IiBtb2RpbmZvIC1rICIka2VybmVsIiAtRiBmaWxlbmFtZSAiJGRyaXZlciIpCiAgICAgICAgICAgIFsgIiRmaWxlbmFtZSIgPSAnKGJ1aWx0aW4pJyBdICYmIGNvbnRpbnVlCiAgICAgICAgICAgIGZpbGVuYW1lPSR7ZmlsZW5hbWUjIyovfQogICAgICAgICAgICBlY2hvICIkbW9kdWxlcyIgfCBncmVwIC1xRiAiLyRmaWxlbmFtZSIgfHwgZGRfZmFpbCAiaW5pdHJhbWZzIG1pc3NpbmcgJGRyaXZlciIKICAgICAgICBkb25lIDwgIiRERF9CVU5ETEUvZHJpdmVycyIKICAgIGRvbmUKICAgIGlmIFsgIiRjb3VudCIgLWVxIDAgXSB8fCBbICEgLXMgIiRyb290L2Jvb3QvZ3J1Yi9ncnViLmNmZyIgXTsgdGhlbiBkZF9mYWlsICdNaXNzaW5nIHRhcmdldCBib290IGZpbGVzJzsgZmkKICAgIGlmIFsgLWQgL3N5cy9maXJtd2FyZS9lZmkgXTsgdGhlbgogICAgICAgIGZpbmQgIiRyb290L2Jvb3QvZWZpL0VGSSIgLXR5cGUgZiAtaW5hbWUgJyouZWZpJyB8IGdyZXAgLXEgLiB8fCBkZF9mYWlsICdNaXNzaW5nIHRhcmdldCBFRkkgbG9hZGVyJwogICAgZmkKICAgIGNocm9vdCAiJHJvb3QiIG5ldHBsYW4gZ2VuZXJhdGUKICAgIGNocm9vdCAiJHJvb3QiIHNzaC1rZXlnZW4gLUEKICAgIG1rZGlyIC1wICIkcm9vdC9ydW4vc3NoZCIKICAgIGNocm9vdCAiJHJvb3QiIC91c3Ivc2Jpbi9zc2hkIC10CiAgICBsb2NhbCBzc2hjb25maWcKICAgIHNzaGNvbmZpZz0kKGNocm9vdCAiJHJvb3QiIC91c3Ivc2Jpbi9zc2hkIC1UKQogICAgZWNobyAiJHNzaGNvbmZpZyIgfCBncmVwIC1xeCAicG9ydCAkc3NoX3BvcnQiIHx8IGRkX2ZhaWwgJ1NTSCBwb3J0IG1pc21hdGNoJwogICAgaWYgWyAtcyAvY29uZmlncy9zc2hfa2V5cyBdOyB0aGVuCiAgICAgICAgZWNobyAiJHNzaGNvbmZpZyIgfCBncmVwIC1xeCAncHVia2V5YXV0aGVudGljYXRpb24geWVzJyB8fCBkZF9mYWlsICdTU0ggcHVibGljIGtleSBhdXRoZW50aWNhdGlvbiBkaXNhYmxlZCcKICAgICAgICBbIC1zICIkcm9vdC9yb290Ly5zc2gvYXV0aG9yaXplZF9rZXlzIiBdIHx8IGRkX2ZhaWwgJ1Jvb3QgYXV0aG9yaXplZF9rZXlzIG1pc3NpbmcnCiAgICAgICAgZWNobyAiJHNzaGNvbmZpZyIgfCBncmVwIC1FcSAnXnBlcm1pdHJvb3Rsb2dpbiAoeWVzfHByb2hpYml0LXBhc3N3b3JkfHdpdGhvdXQtcGFzc3dvcmQpJCcgfHwgZGRfZmFpbCAnUm9vdCBrZXkgbG9naW4gZGlzYWJsZWQnCiAgICBlbHNlCiAgICAgICAgZWNobyAiJHNzaGNvbmZpZyIgfCBncmVwIC1xeCAncGFzc3dvcmRhdXRoZW50aWNhdGlvbiB5ZXMnIHx8IGRkX2ZhaWwgJ1NTSCBwYXNzd29yZCBhdXRoZW50aWNhdGlvbiBkaXNhYmxlZCcKICAgICAgICBlY2hvICIkc3NoY29uZmlnIiB8IGdyZXAgLXF4ICdwZXJtaXRyb290bG9naW4geWVzJyB8fCBkZF9mYWlsICdSb290IHBhc3N3b3JkIGxvZ2luIGRpc2FibGVkJwogICAgICAgIGxvY2FsIHJvb3RfaGFzaAogICAgICAgIHJvb3RfaGFzaD0kKGF3ayAtRjogJyQxID09ICJyb290IiB7cHJpbnQgJDJ9JyAiJHJvb3QvZXRjL3NoYWRvdyIpCiAgICAgICAgY2FzZSAiJHJvb3RfaGFzaCIgaW4gJyd8XCEqfFwqKikgZGRfZmFpbCAnUm9vdCBwYXNzd29yZCBpcyBlbXB0eSBvciBsb2NrZWQnIDs7IGVzYWMKICAgIGZpCiAgICBjcCAiJEREX0JVTkRMRS9uaWNzIiAiJEREX0JVTkRMRS9kcml2ZXJzIiAiJHJvb3QvdmFyL2xpYi91YnVudHUtZGQvIgogICAgZGRfZmluYWxpemVfZGlza19jYWNoZSAiJHJvb3QiCiAgICBlY2hvICdUYXJnZXQga2VybmVsLCBpbml0cmFtZnMsIG5ldHBsYW4gYW5kIFNTSCBjaGVja3MgcGFzc2VkLicKfQo=", "ubuntu-cloudimage-keyring.gpg": "mQINBEqwKTUBEAC8V01JGfeYVVlwlcr0dmwF8n+We/lbxwArjR/gZlH7/MJEZnALQHUrDTpD3SkfbsjQgeNt8eS3Jyzoc2r3t2nos4rXPH4kIzAvtqslz6Ns4ZYjoHVkVC2oV8vYbxER+3/lDjTWVII7omtDVvqH33QlqYZ8+bQbs21lZb2ROJIQCiH0YzaqYR0I2SEykBL873V0ygdyW/mCMwniXTLUyGAUV4/28NOzw/6LGvJElJe4UqwQxl/aXtPIJjPka8LA8+nDi5/u6WEgDWgBhLEHvQG1BNdttm3WCjbu4zS3mNfNBidTamZfOaMJUZVYxhOB5kNQqyR4eYqFK/U+305eLrZ05ocadsmcQWkHQVbgt+g4yyFNl56N5AirkFjVtfArkUJfINGgJ7gkSeyqTJK24f33vsIpPwRQ5eFn7H4PwGc0Piym73YLJnlR94LNEG0ceOJ7u1r+WuaesIj+lKIZsG/rRLf7besaMCCtPcimVgEAmBoIdpTpdP3aa54w/dvfSwW47mGY14G5PBk/0MDy2Y5HOeXat3RXpGZZFh7zbwSQ93RhYH3bNPNd5lMu3ZRkYX19FWxoLCi5lx4K3flYhiolZ5i4KxJCoGRobsKjm74Xv2QlvCXYyAk5BnAQCsu5hKZ1sOhQADCcKz1Zbg8JRc3vmelaJ/VFvHTzs4hJTUvOowARAQABtDRVRUMgSW1hZ2UgQXV0b21hdGljIFNpZ25pbmcgS2V5IDxjZGltYWdlQHVidW50dS5jb20+iQI3BBMBAgAhAhsDAh4BAheABQJKsColBQsJCAcDBRUKCQgLBRYCAwEAAAoJEBpdbEx9uHyBLicP/jXjfLhs255oT8gmvBXS9WDGSdpPiaMxd0CHEyHuT/XdWsoUUYXAPAti8Fyk2K99mze+n4SLCRRJhxqYlcpVy2icc41/VkKI9d/pF4t54RM5TledYpKVV7xTgoUHZpuL2mWzaT61MzRAxUqqaU42/xSLxLt/noryPHo57IghJXbAcmgLhFT0fZmtDy9cD4IBvurZF6cRuMJXjxZmssntMHsFZl4PEC3oR/WgJA37OrjMVej9r+JA909vr5K/UO+P2gWYOH/2CnGDlaTu72wUrLf6QV5jMyKc6+G7fw5bTJd9lE8Km2H+4z9e+t7IOv9oxojvESu27exD4LU7SjzZloYnmlTCsdHwgSJVnf+lqXoZeUNT9Tmku8VzwCoExTwo9exaJUHeO8ABkfsJVmry40ovzQAHh427+6NpxgkWErVocnm54LPIQucZYJrg08s/azRzCjlsYChsaWMvGlMZQo52MuLvETHVPtSggP7sLeIOlS+8tO1ykSJY65j8AHYBV6hb9EOjWmqpx33GXn8AyCPiMs9/pmeOI0V6YMm6HCLAwZb+rRS6gcyt9dlWyLU0QLlpmwHSOVJMv2rnNCUtz6pb8y/o9AN2Z48RpH9C9cfv4dAfbtYn7uTd+M3gk4xyURREg2xuDnraYFs6cZ60/bSy63GxTyi/cCc0S57GgtOK"}


def asset(name):
    if ASSETS:
        return base64.b64decode(ASSETS[name])
    return Path(__file__).with_name(name).read_bytes()


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Patch anchor mismatch: {old[:100]!r}')
    return text.replace(old, new, 1)


def hook(kind):
    return (f'    local dd_rc=0\n    dd_resource {kind} "$@" || dd_rc=$?\n'
            '    if [ "$dd_rc" != 125 ]; then return "$dd_rc"; fi\n')


def patch_host(text):
    # Send the final Ubuntu login password through a private descriptor owned
    # by dd.sh. Never put plaintext in the resource bundle or initramfs.
    text = replace(text, 'prompt_password() {\n',
                   'dd_report_login() {\n'
                   '    [ "${DD_LOGIN_FD:-}" = 8 ] || return 0\n'
                   '    [ "$distro" = ubuntu ] && [ "$username" = root ] &&\n'
                   '        [ "${ssh_port:-22}" = 22 ] && [ -z "${ssh_keys:-}" ] &&\n'
                   '        [ -n "$password" ] || error_and_exit "Unexpected DD login settings"\n'
                   '    printf \'%s\' "$password" >&8 || error_and_exit "Cannot record DD login"\n'
                   '}\n\nprompt_password() {\n')
    text = replace(text, "info 'info'\necho \"$distro $releasever\"",
                   "dd_report_login\ninfo 'info'\necho \"$distro $releasever\"")
    text = replace(text, '        IFS= read -r -p "Password: " password',
                   '        IFS= read -r -s -p "请输入 root 登录密码（留空随机生成）：" password || error_and_exit "未收到密码输入"\n'
                   '        printf "\\n"')
    text = replace(text, '            IFS= read -r -p "Retype password: " password_confirm',
                   '            IFS= read -r -s -p "请再次输入密码：" password_confirm || error_and_exit "未收到确认密码"\n'
                   '            printf "\\n"')
    text = replace(text, 'error "Passwords don\'t match. Try again."',
                   'error "两次密码不一致，请重新输入。"')
    text = replace(text, f'confhome=https://raw.githubusercontent.com/bin456789/reinstall/main',
                   f'confhome=https://raw.githubusercontent.com/bin456789/reinstall/{COMMIT}')
    text = replace(text, 'confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/main',
                   f'confhome_cn=https://cnb.cool/bin456789/reinstall/-/git/raw/{COMMIT}\n'
                   ': "${DD_BUNDLE:?Run through dd.sh}"\n. "$DD_BUNDLE/dd_resources.sh"')
    text = replace(text, 'curl() {\n', 'curl() {\n' + hook('curl'))
    if text.count('command curl --insecure') != 2:
        raise ValueError('Unexpected curl bypass count')
    text = text.replace('command curl --insecure', "command curl --proto '=https' --proto-redir '=https' --tlsv1.2")
    for old in ['http://www.qualcomm.cn', 'http://mirror.nju.edu.cn/alpine', 'http://dl-cdn.alpinelinux.org/alpine']:
        text = text.replace(old, old.replace('http:', 'https:'))
    text = replace(text, '    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh',
                   '    mkdir -p "$initrd_dir/configs/dd"\n'
                   '    cp -a "$DD_BUNDLE/." "$initrd_dir/configs/dd/"\n'
                   '    curl -Lo $initrd_dir/trans.sh $confhome/trans.sh')
    # Alpine initramfs on OCI Arm can start with an unset clock. Carry the
    # host CA bundle and a trusted time floor instead of disabling TLS checks.
    text = replace(text, 'mod_initrd_alpine() {\n', 'mod_initrd_alpine() {\n'
                   '    [ -s /etc/ssl/certs/ca-certificates.crt ] || error_and_exit "CA bundle missing"\n'
                   '    mkdir -p "$initrd_dir/etc/ssl/certs"\n'
                   '    cp /etc/ssl/certs/ca-certificates.crt "$initrd_dir/etc/ssl/certs/"\n'
                   '    local dd_epoch\n    dd_epoch=$(date +%s)\n'
                   '    grep -q "^#!/bin/sh" init || error_and_exit "Unexpected Alpine init"\n'
                   '    insert_into_file init after "^#!/bin/sh" <<EOF\n'
                   'if [ "\\$(/bin/busybox date +%s)" -lt "$dd_epoch" ]; then /bin/busybox date -u -s @$dd_epoch; fi\n'
                   'EOF\n')
    text = replace(text, '        cp /trans.sh \\$sysroot/etc/local.d/trans.start',
                   '        mkdir -p \\$sysroot/etc/ssl/certs\n'
                   '        cp /etc/ssl/certs/ca-certificates.crt \\$sysroot/etc/ssl/certs/\n'
                   '        cp /trans.sh \\$sysroot/etc/local.d/trans.start')
    return text


def patch_network_unit(text):
    # Ubuntu's cloud-init-local runs before sysinit. A regular service ordered
    # before it must not also inherit After=basic/sysinit or wait for D-Bus.
    text = replace(text, '[Unit]\n', '[Unit]\nDefaultDependencies=no\n'
                   'Wants=systemd-udev-settle.service\n'
                   'Conflicts=shutdown.target\nBefore=shutdown.target\n')
    return replace(text, 'After=dbus.service\n',
                   'After=systemd-remount-fs.service systemd-udev-settle.service\n')


def patch_trans(text):
    # Ignore the old /configs/xda cache and reject cloned table IDs instead of
    # selecting the first enumerated device. Identity is sealed by the host.
    matches = re.findall(r'^find_xda\(\) \{\n.*?^\}', text, re.M | re.S)
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous upstream disk selector')
    # Alpine ships the blockdev command in util-linux-misc, not a blockdev APK.
    text = replace(text, matches[0], 'find_xda() {\n'
                   '    apk add lsblk util-linux-misc eudev\n'
                   '    dd_find_target_disk\n'
                   '    set_config xda "$xda"\n}')
    text = replace(text, 'get_ubuntu_kernel_flavor() {\n', 'dd_upstream_kernel_flavor() {\n')
    text = replace(text, 'wget() {\n', 'wget() {\n' + hook('wget'))
    text = replace(text, 'download() {\n', 'download() {\n' + hook('download'))
    # All external file downloads used by the Ubuntu path go through strict
    # HTTPS. APK/APT keep their native signed-package validation.
    text = replace(text, '    local url=$1\n    local path=$2\n    local can_use_cn_mirror=',
                   '    case "$1" in https://*) ;; *) dd_fail "Non-HTTPS download refused" ;; esac\n'
                   '    dd_https --output "$2" "$1"\n    return\n'
                   '    local url=$1\n    local path=$2\n    local can_use_cn_mirror=')
    text = replace(text, '    show_url_in_args "$@" >&2\n    if command wget',
                   '    dd_wget "$@"\n    return\n    show_url_in_args "$@" >&2\n    if command wget')
    text = replace(text, ': main\n', ': main\n'
                   'DD_BUNDLE=/configs/dd\n'
                   '(cd "$DD_BUNDLE" && sha256sum -c resources.sha256 >/dev/null) || exit 1\n'
                   '. "$DD_BUNDLE/dd_resources.sh"\n'
                   '. "$DD_BUNDLE/dd_disk.sh"\n'
                   '. "$DD_BUNDLE/dd_runtime.sh"\n'
                   '. "$DD_BUNDLE/dd_packages.sh"\n'
                   '[ "$#" = 0 ] || dd_fail "Stage updates and alternate installations are disabled"\n'
                   'dd_install_begin\n')
    # The upstream retry hint restarts repartitioning. After disk writes begin,
    # preserve the installer and explain the actual failure boundary instead.
    begin = text.index('error_and_exit() {\n')
    end = text.index('\ntrap_err() {', begin)
    text = text[:begin] + 'error_and_exit() {\n    dd_fail "$@"\n}\n' + text[end:]
    begin = text.index('trap_err() {\n')
    end = text.index('\nis_run_from_locald() {', begin)
    text = text[:begin] + ('trap_err() {\n'
                          '    echo "DD command failed at line $1 (exit $2)" >&2\n'
                          '    exit "$2"\n}\n') + text[end:]
    text = replace(text, '    wget -O /trans.sh "$confhome/trans.sh"',
                   '    dd_fail "Self-update is disabled; prepare again with dd.sh"')
    text = replace(text, 'create_part() {\n', 'create_part() {\n    dd_require_partition\n')
    text = replace(text, '        qemu)\n            create_part\n            download_qcow',
                   '        qemu)\n            dd_prepare_install')
    # In disk mode the installer partition contains the live swap file. Keep
    # it mounted and retain it for target swap instead of removing a live swap.
    text = replace(text, '    umount /os/\n    umount /installer/\n',
                   '    umount /os/\n    dd_release_installer\n')
    text = replace(text, '    parted /dev/$xda -s -- rm 3\n    update_part\n    resize_after_install_cloud_image\n',
                   '    dd_finish_partition_layout\n')
    text = replace(text, '    create_swap_if_ram_less_than $need_ram /os/swapfile\n',
                   '    if ! dd_disk_cache; then create_swap_if_ram_less_than $need_ram /os/swapfile; fi\n')
    text = replace(text, '    # 删除 swapfile\n    swapoff -a\n    rm -f /os/swapfile\n',
                   '    # Disk cache swap remains available until reboot and in the target.\n'
                   '    if ! dd_disk_cache; then swapoff -a; rm -f /os/swapfile; fi\n')
    text = replace(text, '    remove_or_disable_cloud_init /os\n',
                   '    dd_finalize_target /os\n')
    text = replace(text, '    while ! blkid /dev/nbd0; do\n',
                   '    local dd_wait=0\n    while ! blkid /dev/nbd0; do\n'
                   '        dd_wait=$((dd_wait + 1))\n'
                   '        [ "$dd_wait" -le 24 ] || dd_fail "nbd attach timed out"\n')
    # Only the image handle matters here. Whole-filesystem fuser (-m) also
    # sees unrelated scratch/log files and can wait forever in disk mode.
    text = replace(text, '        while fuser -sm $qcow_file; do\n',
                   '        local dd_detach_wait=0\n'
                   '        while fuser -s "$qcow_file"; do\n'
                   '            dd_detach_wait=$((dd_detach_wait + 1))\n'
                   '            [ "$dd_detach_wait" -le 24 ] || dd_fail "nbd detach timed out"\n')
    # The preflight NBD must remain read-only until detached; later calls write
    # only the already checked disk copy. Pin format for all NBD use.
    text = replace(text, '    qemu-nbd -c /dev/nbd0 $qcow_file',
                   '    qemu-nbd --format=qcow2 -c /dev/nbd0 $qcow_file')
    text = replace(text, '    cp -a /nbd/* /os/\n',
                   '    dd_install_stage target-copy\n    cp -a /nbd/* /os/\n    dd_seed_packages /os\n')
    # Keep preflight APT URIs/index names unchanged. The image uses official
    # Ubuntu sources; a mirror switch here would invalidate the cached plan.
    begin = text.index('        # 更改源\n', text.index('    modify_ubuntu() {'))
    end = text.index('        # 安装 mbr\n', begin)
    text = text[:begin] + ('        dd_install_stage package-install\n'
                         '        dd_install_packages "$os_dir"\n'
                         '        # Retain unused bootloader packages; removing them can\n'
                         '        # trigger a different APT dependency transaction.\n\n') + text[end:]
    text = replace(text, '        chroot $os_dir apt-get update', '        dd_apt_update "$os_dir"')
    text = replace(text, 'chroot $os_dir apt-get install -y $pkgs', 'chroot $os_dir apt-get --no-download install -y $pkgs')
    text = replace(text, 'chroot $os_dir apt-get remove --purge --allow-remove-essential -y $pkgs',
                   'chroot $os_dir apt-get --no-download remove --purge -y $pkgs')
    text = replace(text, 'chroot $os_dir apt-get autoremove --purge -y',
                   'chroot $os_dir apt-get --no-download autoremove --purge -y')
    # No HTTP Date / certificate bypass is needed for the installer clock.
    start = text.index('sync_time() {\n')
    end = text.index('\nis_ubuntu_lts() {', start)
    text = text[:start] + 'sync_time() {\n    : # Keep the initramfs time floor; no unsigned HTTP clock source.\n}\n' + text[end:]
    text = replace(text, '    dd_finalize_target /os\n',
                   '    dd_install_stage target-validation\n    dd_finalize_target /os\n')
    text = replace(text, "    info 'done'\n", "    dd_install_stage complete\n    info 'done'\n")
    return text


def build(archive, target):
    archive, target = Path(archive), Path(target)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA:
        raise ValueError('Upstream archive SHA-256 mismatch')
    target.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'r:gz') as tar:
        for item in tar:
            parts = PurePosixPath(item.name).parts
            if not parts or parts[0] != f'reinstall-{COMMIT}' or '..' in parts:
                raise ValueError('Unsafe archive path')
            # Only root-level regular helper files are used by Ubuntu.
            if len(parts) != 2 or not item.isfile():
                continue
            path = target / parts[1]
            if path.is_symlink():
                raise ValueError('Symlink in bundle output')
            path.write_bytes(tar.extractfile(item).read())
    for name, patch in [('reinstall.sh', patch_host), ('trans.sh', patch_trans),
                        ('fix-eth-name.service', patch_network_unit)]:
        p = target / name
        p.write_text(patch(p.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    for name in ['dd_resources.sh', 'dd_disk.sh', 'dd_runtime.sh', 'dd_packages.sh', 'ubuntu-cloudimage-keyring.gpg']:
        (target / name).write_bytes(asset(name))
    seal(target)


def seal(target):
    target = Path(target)
    lines = []
    for path in sorted(target.iterdir()):
        if path.is_file() and path.name != 'resources.sha256':
            lines.append(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n')
    (target / 'resources.sha256').write_text(''.join(lines), encoding='ascii')


class HTTPSOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Non-HTTPS redirect refused')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def snapshot_base(client, version, codename):
    current = f'https://cloud-images.ubuntu.com/releases/{codename}/release/'
    with client.open(current, timeout=60) as response:
        if response.geturl() != current:
            raise ValueError('Release index redirected away from official current build')
        data = response.read(2 * 1024 * 1024)
    if len(data) >= 2 * 1024 * 1024:
        raise ValueError('Release index too large')
    # The official current-release heading identifies the published serial;
    # directory order and timestamps are not a reliable latest-build selector.
    matches = re.findall(r'<h1>Ubuntu ' + re.escape(version) +
                         r'(?=[ .])[^<]* release \[([0-9]{8}(?:\.[0-9]+)?)\]</h1>', data.decode('utf-8'))
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous Ubuntu release build')
    serial = matches[0]
    datetime.strptime(serial.split('.')[0], '%Y%m%d')
    return current.removesuffix('release/') + 'release-' + serial + '/', serial


def image_metadata(target, version, arch):
    target = Path(target)
    # A failed refresh must not leave a previously usable image policy behind.
    for field in ['image-url', 'image-build', 'image-bytes']:
        (target / field).unlink(missing_ok=True)
    codename = {'24.04': 'noble', '26.04': 'resolute'}[version]
    if arch not in ['amd64', 'arm64']:
        raise ValueError('Unsupported image architecture')
    name = f'ubuntu-{version}-server-cloudimg-{arch}.img'
    client = urllib.request.build_opener(HTTPSOnly())
    base, serial = snapshot_base(client, version, codename)
    for resource in ['SHA256SUMS', 'SHA256SUMS.gpg']:
        with client.open(base + resource, timeout=60) as response:
            if response.geturl() != base + resource:
                raise ValueError('Snapshot manifest redirected away from pinned build')
            data = response.read(2 * 1024 * 1024)
        if len(data) >= 2 * 1024 * 1024:
            raise ValueError('Manifest too large')
        (target / resource).write_bytes(data)
    import tempfile
    with tempfile.TemporaryDirectory(prefix='dd-gpg-') as home:
        subprocess.run(['gpgv', '--homedir', home, '--keyring', str(target.resolve() / 'ubuntu-cloudimage-keyring.gpg'),
                        str(target / 'SHA256SUMS.gpg'), str(target / 'SHA256SUMS')], check=True)
    matches = re.findall(r'^([a-f0-9]{64}) [ *]' + re.escape(name) + r'$',
                         (target / 'SHA256SUMS').read_text(encoding='ascii'), re.M)
    if len(matches) != 1:
        raise ValueError('Missing or ambiguous signed Ubuntu image entry')
    with client.open(urllib.request.Request(base + name, method='HEAD'), timeout=60) as response:
        if response.geturl() != base + name:
            raise ValueError('Snapshot image redirected away from pinned build')
        size = int(response.headers['Content-Length'])
    if not 64 * 1024 * 1024 < size < 16 * 1024 ** 3:
        raise ValueError('Unexpected image size')
    (target / 'image-url').write_text(base + name + '\n', encoding='ascii')
    (target / 'image-build').write_text(serial + '\n', encoding='ascii')
    (target / 'image-bytes').write_text(str(size) + '\n', encoding='ascii')
    print(f'Ubuntu {version} {arch}, build {serial}: {size} bytes; signed SHA256 {matches[0]}')


if __name__ == '__main__':
    try:
        action, *args = sys.argv[1:]
        {'build': build, 'image': image_metadata, 'seal': seal}[action](*args)
    except Exception as exc:
        sys.exit(f'DD preparation stopped: {exc}')
PY_DD
}
# END DD ENGINE

prepare_image_policy() {
    need gpgv; need blockdev
    local arch bytes total i path module
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; esac
    engine_tools image "$DD_BUNDLE" "$UBUNTU_VERSION" "$arch"
    DD_IMAGE_URL=$(cat "$DD_BUNDLE/image-url")
    bytes=$(cat "$DD_BUNDLE/image-bytes")
    total=$(awk '/MemTotal:/ {printf "%.0f", $2*1024}' /proc/meminfo)
    # MemTotal excludes firmware/kernel reservations on a nominal 512 MiB VM.
    (( total >= 469762048 )) || die '至少需要标称 512 MiB 内存（MemTotal 至少 448 MiB）。'
    if [[ $CACHE_MODE == auto ]]; then
        if (( total >= bytes + 2415919104 )); then CACHE_MODE=ram; else CACHE_MODE=disk; fi
    fi
    if [[ $CACHE_MODE == ram ]]; then
        (( total >= bytes + 2415919104 )) || die 'RAM 模式内存不足；请使用 --cache-mode disk。'
    else
        local disk_bytes
        disk_bytes=$(blockdev --getsize64 "$SYSTEM_DISK")
        (( disk_bytes >= 17179869184 && disk_bytes >= bytes + 12884901888 )) || die '磁盘缓存模式需要至少 16 GiB 系统盘，并留足镜像缓存和系统空间。'
    fi
    printf '%s\n' "$CACHE_MODE" > "$DD_BUNDLE/cache-mode"
    say "安装缓存模式：$CACHE_MODE"
    printf '%s\n' "$CLOUD" > "$DD_BUNDLE/cloud"
    dd_record_disk_identity "$SYSTEM_DISK"
    : > "$DD_BUNDLE/nics"
    : > "$DD_BUNDLE/drivers"
    (( ${#NIC_NAMES[@]} > 0 )) || die '没有识别到实际网卡。'
    for i in "${!NIC_NAMES[@]}"; do
        module=${NIC_DRIVERS[$i]}
        [[ $module =~ ^[a-zA-Z0-9_]+$ && $module != unknown ]] || die '存在无法识别的网卡驱动。'
        printf '%s %s\n' "$(cat "$SYS_ROOT/class/net/${NIC_NAMES[$i]}/address")" "$module" >> "$DD_BUNDLE/nics"
        printf '%s\n' "$module" >> "$DD_BUNDLE/drivers"
    done
    for module in virtio_pci virtio_blk virtio_scsi nvme xen_blkfront xen_scsifront hv_storvsc ahci; do
        path=$SYS_ROOT/module/$module
        [[ ! -d $path ]] || printf '%s\n' "$module" >> "$DD_BUNDLE/drivers"
    done
    sort -u -o "$DD_BUNDLE/drivers" "$DD_BUNDLE/drivers"
    engine_tools seal "$DD_BUNDLE"
}

dd_login_password() {
    local file=$STATE/login-password password
    [[ -f $file && ! -L $file && $(stat -c %u -- "$file") == "$EUID" &&
       $(stat -c %a -- "$file") == 600 ]] || die '重装登录信息缺失或权限异常，请取消重装后重新准备。'
    # The sentinel preserves trailing newlines so malformed records are rejected.
    password=$(cat -- "$file" && printf '.') || die '读取重装登录信息失败。'
    password=${password%.}
    [[ -n $password && $password != *[[:cntrl:]]* ]] || die '重装密码记录无效，请取消重装后重新准备。'
    printf '%s' "$password"
}

show_dd_login() {
    [[ -e $STATE/reinstall-pending || -L $STATE/reinstall-pending ]] || return 0
    [[ -f $STATE/reinstall-pending && ! -L $STATE/reinstall-pending &&
       -f $STATE/reinstall-ready && ! -L $STATE/reinstall-ready ]] ||
        die '重装尚未完成准备或缺少登录信息，请先取消重装并重新准备。'
    local password
    password=$(dd_login_password) || return 1
    menu_line title '重装后登录信息：'
    menu_line info '用户名：root'
    menu_line recovery "密码：$password"
    say 'SSH 端口：22'
}

show_reinstall_target() {
    [[ -t 0 && -t 1 ]] || die '重装必须在交互终端操作；请下载脚本后运行，不要管道执行。'
    say "目标：Ubuntu $UBUNTU_VERSION，SSH 端口 22，系统盘 $SYSTEM_DISK"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS "$SYSTEM_DISK"
    if (( TEST_NETWORK )); then
        say '首次重启只进入安装环境；随后运行 /trans.sh 会清除此盘所有数据。'
    else
        say '重启后会清除此磁盘的所有分区和数据。'
    fi
    say '请确认备份可用，并准备好对应云平台的恢复方案。'
    if [[ $CACHE_MODE != ram ]]; then
        say '低内存磁盘缓存模式会先清盘分区，再下载验证镜像和软件包；断网或验证失败不能恢复原系统。'
        say '该模式保留至少 6 GiB 缓存分区和 2 GiB swap，供安装及新系统使用。'
    fi
    say '开始准备重装；完成后返回主菜单，不自动重启。重启前仍可取消待执行重装。'
}

reinstall_ubuntu() {
    if (( DRY_RUN )); then
        say "[预览] 重装目标 Ubuntu $UBUNTU_VERSION；SSH 端口 22。"
        say '[预览] 识别根文件系统的唯一整盘，显示目标盘和分区后准备重装；仅在菜单重启时确认。'
        say '[预览] root 密码登录，安装引擎将提示设置密码；留空生成随机密码。'
        say "[预览] 校验完整资源包；辅助脚本离线携带，固定资源版本 $REINSTALL_COMMIT。"
        say "[预览] 缓存模式 $CACHE_MODE；auto 按内存选择 RAM 或磁盘缓存，最低标称 512 MiB。"
        say '[预览] RAM 模式先验证再清盘；磁盘模式先验证签名和网络，再清盘建立缓存/swap，之后下载校验并安装。'
        say '[预览] 传入明确的系统盘，准备重装引导；不自动重启。'
        say "[预览] 平台 $CLOUD；自动识别真实网卡驱动，检查 gVNIC；安装环境网络测试模式：$TEST_NETWORK。"
        return
    fi
    [[ ! -e $STATE/reinstall-pending && ! -L $STATE/reinstall-pending ]] || die '已有重装准备记录；请先在菜单取消待执行重装，避免覆盖。'
    need curl; need sha256sum
    secure_boot_check
    inspect_cloud
    case "$(uname -m)" in x86_64|aarch64) ;; *) die '只支持 amd64 / arm64。' ;; esac
    detect_system_disk
    show_reinstall_target
    prepare_engine
    prepare_image_policy
    {
        printf 'cloud=%s\ngvnic=%s\n' "$CLOUD" "$HAS_GVNIC"
        local i
        for i in "${!NIC_NAMES[@]}"; do printf 'nic=%s driver=%s\n' "${NIC_NAMES[$i]}" "${NIC_DRIVERS[$i]}"; done
    } > "$STATE/cloud-report"
    local -a args=(ubuntu "$UBUNTU_VERSION" --target-disk "$SYSTEM_DISK" --ssh-port 22 --commit "$REINSTALL_COMMIT" --ci --img "$DD_IMAGE_URL" --username root)
    (( !TEST_NETWORK )) || args+=(--hold 1)
    rm -f -- "$STATE/login-password" "$STATE/reinstall-ready"
    (umask 077; set -C; : > "$STATE/login-password")
    # 提前记录：上游失败时可能已经部分修改引导，仍应提供 cancel 路径。
    printf 'ubuntu=%s\ndisk=%s\nengine=%s\n' "$UBUNTU_VERSION" "$SYSTEM_DISK" "$REINSTALL_COMMIT" > "$STATE/reinstall-pending"
    if ! DD_LOGIN_FD=8 bash "$ENGINE" "${args[@]}" 8>"$STATE/login-password"; then
        rm -f -- "$STATE/login-password"
        die '重装准备失败，可能已部分修改引导。不要重启，请先在菜单取消待执行重装。'
    fi
    dd_login_password >/dev/null || die '未能保存重装登录信息，请先取消重装并重新准备。'
    printf 'ubuntu=%s\n' "$UBUNTU_VERSION" > "$STATE/reinstall-ready"
    if (( TEST_NETWORK )); then
        say '网络测试引导已准备。重启后先 SSH 登录安装环境，检查网卡、地址和默认路由。'
        say '确认联网后运行 /trans.sh 才会开始清盘重装；此时原系统菜单的取消功能已不可用。'
    else
        say 'Ubuntu 重装已准备，尚未重启。选择“重启系统”时将再次显示登录信息。'
    fi
    show_dd_login
    say '尚未重启时，可在菜单选择“取消待执行重装”。'
    say '重装将清除本工具和自编译内核；新系统启动后重新打开 BBR 菜单安装实验内核。'
}

cancel_reinstall() {
    if (( DRY_RUN )); then say '[预览] 使用固定版本引擎 reset 取消重装引导，不重启。'; return; fi
    prepare_engine
    bash "$ENGINE" reset --commit "$REINSTALL_COMMIT"
    rm -f -- "$STATE/reinstall-pending" "$STATE/reinstall-ready" "$STATE/login-password"
    say '已执行重装引导清理。此操作不能恢复已经被重装覆盖的数据。'
}


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

menu_reinstall_options() {
    menu_line title '选择 Ubuntu 版本：'
    menu_line danger '1、Ubuntu 24.04（推荐）'
    menu_line danger '2、Ubuntu 26.04'
    menu_line exit '0、退出'
    menu_choice 1 2
    case "$REPLY" in 1) UBUNTU_VERSION=24.04 ;; 2) UBUNTU_VERSION=26.04 ;; esac
    say "已选择 Ubuntu $UBUNTU_VERSION，root 密码登录，SSH 端口 22。"
}

menu() {
    require_menu_terminal
    while true; do
        DRY_RUN=0; CLOUD=auto; UBUNTU_VERSION=24.04; TEST_NETWORK=0; CACHE_MODE=auto
        say ''
        menu_line title "===== Ubuntu DD 中文菜单 $TOOL_VERSION ====="
        menu_line danger '1、重装系统'
        menu_line info '2、查看系统与网卡状态'
        menu_line recovery '3、取消待执行重装'
        menu_line danger '4、重启系统'
        menu_line exit '0、退出'
        menu_choice 1 2 3 4
        case "$REPLY" in
            1) ACTION=reinstall ;; 2) ACTION=status ;; 3) ACTION=cancel ;; 4) ACTION=reboot ;;
        esac
        if [[ $ACTION == reinstall ]]; then menu_reinstall_options; fi
        run_menu_action
    done
}

dispatch() {
    case "$ACTION" in status) cloud_status; return ;; esac
    if (( !DRY_RUN )); then require_host; fi
    case "$ACTION" in
        reinstall) reinstall_ubuntu ;; cancel) cancel_reinstall ;;
        reboot) if (( !DRY_RUN )); then show_dd_login; fi; reboot_host confirm ;;
        *) die '无效内部操作。' ;;
    esac
}

main() {
    (( $# == 0 )) || die '已改为中文数字菜单，请直接运行 sudo bash dd.sh，不要附加命令或参数。'
    require_menu_terminal
    run_latest_release dd.sh "${BASH_SOURCE[0]}"
    menu
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
