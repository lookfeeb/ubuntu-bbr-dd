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
