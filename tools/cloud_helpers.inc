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
