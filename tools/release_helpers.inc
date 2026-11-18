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
