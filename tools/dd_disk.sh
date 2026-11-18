#!/bin/sh
# shellcheck shell=dash
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
