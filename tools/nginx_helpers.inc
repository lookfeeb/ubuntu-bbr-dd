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
