#!/bin/sh
# shellcheck shell=dash
# shellcheck disable=SC3043,SC2154
# Common resource adapter used by Bash (host) and BusyBox ash (installer).
# Return 125 only when the request is not for the pinned upstream bundle.
dd_resource() {
    local mode="$1" url='' output=- arg name expected actual
    shift
    if [ "$mode" = download ]; then
        url=$1; output=$2
    else
        while [ "$#" -gt 0 ]; do
            arg=$1; shift
            case "$arg" in
                https://raw.githubusercontent.com/bin456789/reinstall/*|https://cnb.cool/bin456789/reinstall/-/git/raw/*) url=$arg ;;
                -o|-Lo|--output) [ "$mode" = curl ] || continue; output=$1; shift ;;
                -O) if [ "$mode" = wget ]; then output=$1; shift; else output=auto; fi ;;
                -O-) [ "$mode" != wget ] || output=- ;;
                -LO) output=auto ;;
            esac
        done
    fi
    case "$url" in
        https://raw.githubusercontent.com/bin456789/reinstall/*|https://cnb.cool/bin456789/reinstall/-/git/raw/*) ;;
        *) return 125 ;;
    esac
    name=${url##*/}
    case "$name" in ''|.*|*[!a-zA-Z0-9_.-]*) echo 'Invalid bundle resource' >&2; return 1 ;; esac
    [ "${url%/*}" = "$confhome" ] || { echo 'Unpinned resource URL refused' >&2; return 1; }
    expected=$(awk -v n="$name" '$2 == n {print $1}' "$DD_BUNDLE/resources.sha256") || return 1
    if [ -z "$expected" ] || [ ! -f "$DD_BUNDLE/$name" ]; then echo "Missing pinned resource: $name" >&2; return 1; fi
    actual=$(sha256sum "$DD_BUNDLE/$name") || return 1
    [ "${actual%% *}" = "$expected" ] || { echo "Resource checksum failed: $name" >&2; return 1; }
    [ "$output" != auto ] || output=$name
    if [ "$output" = - ]; then cat "$DD_BUNDLE/$name"; else cp "$DD_BUNDLE/$name" "$output"; fi
}
