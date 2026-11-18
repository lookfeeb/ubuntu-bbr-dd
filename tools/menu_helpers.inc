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
