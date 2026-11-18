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
