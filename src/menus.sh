# ==================== 主菜单与交互界面 ====================

menu_logo() {
    clear_screen
    print_divider
    printf '%b' "$PURPLE$BOLD"
    cat <<'EOF'
   _____ ____  _  __
  / ___// __ )| |/ /   Sing-box & Linux VPS 工具箱
  \__ \/ __  ||   /    版本: v5.0.0  |  快捷指令: sbx
 ___/ / /_/ //   |     纯净·轻量·一键运维
/____/_____//_/|_|
EOF
    printf '%b' "$NC"
    print_divider

    # 快捷状态摘要
    local os_brief cores load mem_pct sbx_stat
    os_brief=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 | awk '{print $1" "$2}')
    [ -n "$os_brief" ] || os_brief="Linux"
    cores=$(nproc 2>/dev/null || echo "1")
    load=$(awk '{print $1" "$2}' /proc/loadavg 2>/dev/null || echo "0.0")
    mem_pct=$(free 2>/dev/null | awk 'NR==2{printf "%.0f%%", $3*100/$2}')
    sbx_stat=$(sbx_service_status)

    printf "  %b系统:%b %s (%s核) | %b负载:%b %s | %b内存:%b %s | %b代理:%b %b\n" \
        "$CYAN" "$NC" "$os_brief" "$cores" \
        "$CYAN" "$NC" "$load" \
        "$CYAN" "$NC" "$mem_pct" \
        "$CYAN" "$NC" "$sbx_stat"
    print_divider
}

show_main_menu() {
    menu_logo

    printf '  %b[ 系统维护 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 1 "系统状态总览" 2 "系统更新与组件安装"
    menu_pair 3 "系统垃圾清理" 4 "修改 Root 密码"
    menu_single 5 "主机名与时区配置"

    printf '\n  %b[ 网络优化与安全 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 6 "Swap 虚拟内存" 7 "DNS 优化与修改"
    menu_pair 8 "TCP 调优与 BBR" 9 "BestTrace 回程测试"
    menu_pair 10 "流媒体与 IP 质量" 11 "UFW 防火墙端口管理"

    printf '\n  %b[ Sing-box 代理 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 12 "VLESS-Reality 节点" 13 "TCP/UDP 端口转发"
    menu_pair 14 "WARP 出口与分流" 15 "核心与服务维护"

    printf '\n  %b[ 脚本管理 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_single 16 "彻底卸载 SBX (清除全部配置与残留)"

    printf '\n'
    print_divider
    printf "  %b 0.%b 退出脚本\n\n" "$YELLOW" "$NC"

    _read_menu_choice MAIN_OPT "> 请选择操作 [0-16]: "
    case "$MAIN_OPT" in
        1) system_overview ;;
        2) system_update ;;
        3) system_clean ;;
        4) change_root_password ;;
        5) manage_host_time ;;
        6) manage_swap ;;
        7) optimize_dns ;;
        8) manage_tcp_bbr ;;
        9) check_return_route ;;
        10) check_media_unlock ;;
        11) manage_ufw ;;
        12) manage_reality ;;
        13) manage_forward ;;
        14) manage_warp ;;
        15) manage_service ;;
        16) uninstall_all ;;
        0)
            printf '\n%b感谢使用，再见！%b\n\n' "$GREEN" "$NC"
            exit 0
            ;;
        *)
            printf '\n%b[!] 选项无效，请输入 0-16 之间的数字。%b\n' "$RED" "$NC"
            sleep 1
            ;;
    esac
}

main() {
    set +x
    umask 077
    [ "$EUID" -eq 0 ] || {
        printf '%b[!] 请以 root 用户身份运行此脚本。%b\n' "$RED" "$NC" >&2
        exit 1
    }
    platform_detect

    # 仅在非交互重定向且终端存在时切回 /dev/tty
    if [ ! -t 0 ] && [ -r /dev/tty ] && [ -t 1 ]; then
        exec < /dev/tty
    fi

    while true; do
        show_main_menu
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
