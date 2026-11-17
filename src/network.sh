# ==================== 网络优化与安全 ====================

manage_swap() {
    while true; do
        menu_header "Swap 虚拟内存"
        local swap_total swap_used
        swap_total=$(free -m 2>/dev/null | awk 'NR==3{print $2}')
        swap_used=$(free -m 2>/dev/null | awk 'NR==3{print $3}')
        if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
            printf "  %b状态:%b %b未启用%b\n\n" "$CYAN" "$NC" "$YELLOW" "$NC"
        else
            printf "  %b状态:%b %b%s / %s MB%b\n\n" "$CYAN" "$NC" "$GREEN" "$swap_used" "$swap_total" "$NC"
        fi
        menu_pair 1 "设为 1GB" 2 "设为 2GB"
        menu_pair 3 "设为 4GB" 4 "自定义大小"
        menu_single 5 "关闭并删除 Swap"
        menu_single 0 "返回"
        _read_menu_choice swap_opt "> 选择 [0-5]: "
        local mb_size=0
        case "$swap_opt" in
            1) mb_size=1024 ;;
            2) mb_size=2048 ;;
            3) mb_size=4096 ;;
            4)
                read -rp "  输入大小 (MB, >=128): " mb_size; mb_size="${mb_size// /}"
                [[ "$mb_size" =~ ^[0-9]+$ ]] && [ "$mb_size" -ge 128 ] || { printf '%b[!] 大小无效%b\n' "$RED" "$NC"; pause_for_enter; continue; } ;;
            5)
                confirm_action "关闭并删除 /swapfile？" || continue
                swapoff -a 2>/dev/null || true; sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true; rm -f /swapfile
                printf '%b[OK] Swap 已移除%b\n' "$GREEN" "$NC"; pause_for_enter; continue ;;
            0) return 0 ;;
            *) continue ;;
        esac
        confirm_action "分配 ${mb_size} MB Swap？" || continue
        swapoff -a 2>/dev/null || true; sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true; rm -f /swapfile
        fallocate -l "${mb_size}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$mb_size" status=none
        chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile >/dev/null 2>&1
        grep -q '/swapfile' /etc/fstab || echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
        sysctl -w vm.swappiness=20 >/dev/null 2>&1 || true
        printf '%b[OK] Swap (%sMB) 已启用%b\n' "$GREEN" "$mb_size" "$NC"
        pause_for_enter
    done
}

_apply_dns() {
    local d1="$1" d2="${2:-$1}" bak="/etc/resolv.conf.sbx_bak"
    [ -f "$bak" ] || cp -p /etc/resolv.conf "$bak" 2>/dev/null || true
    chattr -i /etc/resolv.conf 2>/dev/null || true
    printf 'nameserver %s\nnameserver %s\noptions timeout:2 attempts:3 rotate\n' "$d1" "$d2" > /etc/resolv.conf
    printf '%b[OK] DNS 已设为: %s, %s%b\n' "$GREEN" "$d1" "$d2" "$NC"
}

optimize_dns() {
    while true; do
        menu_header "DNS 优化"
        local cur_dns
        cur_dns=$(awk '/nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
        printf "  %b当前 DNS:%b %s\n\n" "$CYAN" "$NC" "${cur_dns:-无}"
        menu_single 1 "国际 DNS (1.1.1.1 + 8.8.8.8)"
        menu_single 2 "国内 DNS (223.5.5.5 + 119.29.29.29)"
        menu_single 3 "自定义 DNS"
        menu_single 4 "还原备份"
        menu_single 0 "返回"
        _read_menu_choice dns_opt "> 选择 [0-4]: "
        case "$dns_opt" in
            1) _apply_dns "1.1.1.1" "8.8.8.8"; pause_for_enter ;;
            2) _apply_dns "223.5.5.5" "119.29.29.29"; pause_for_enter ;;
            3)
                local d1 d2
                read -rp "  首选 DNS: " d1; read -rp "  备选 DNS (可空): " d2
                d1="${d1// /}"; d2="${d2// /}"
                [ -n "$d1" ] && { _apply_dns "$d1" "${d2:-$d1}"; pause_for_enter; } ;;
            4)
                if [ -f /etc/resolv.conf.sbx_bak ]; then
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    cp -pf /etc/resolv.conf.sbx_bak /etc/resolv.conf
                    printf '%b[OK] 已还原 DNS%b\n' "$GREEN" "$NC"
                else
                    printf '%b[!] 无备份%b\n' "$YELLOW" "$NC"
                fi
                pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}

manage_tcp_bbr() {
    while true; do
        menu_header "TCP 调优与 BBR"
        local cur_cc cur_qdisc st
        cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        [ -f "$TCP_SYSCTL_CONF" ] && st="${GREEN}已调优${NC}" || st="${DIM}默认${NC}"
        printf "  %b拥塞算法:%b %s  |  %b队列:%b %s  |  %b状态:%b %b\n\n" "$CYAN" "$NC" "$cur_cc" "$CYAN" "$NC" "$cur_qdisc" "$CYAN" "$NC" "$st"
        menu_single 1 "开启原生 BBR + FQ"
        menu_single 2 "应用高吞吐并发调优 (含 BBR)"
        menu_single 3 "查看调优参数"
        menu_single 4 "恢复默认参数"
        menu_single 0 "返回"
        _read_menu_choice tcp_opt "> 选择 [0-4]: "
        case "$tcp_opt" in
            1)
                confirm_action "启用原生 BBR + FQ？" || continue
                modprobe tcp_bbr 2>/dev/null || true
                sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
                sed -i '/net.core.default_qdisc/d;/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
                printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' >> /etc/sysctl.conf
                printf '%b[OK] BBR + FQ 已启用%b\n' "$GREEN" "$NC"; pause_for_enter ;;
            2)
                confirm_action "应用 TCP 高吞吐并发参数？" || continue
                cat > "$TCP_SYSCTL_CONF" <<'EOF'
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 60000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_syncookies = 1
EOF
                sysctl -p "$TCP_SYSCTL_CONF" >/dev/null 2>&1 || true
                printf '%b[OK] 调优参数已生效%b\n' "$GREEN" "$NC"; pause_for_enter ;;
            3) [ -f "$TCP_SYSCTL_CONF" ] && cat "$TCP_SYSCTL_CONF" || printf '%b[!] 未生成调优文件%b\n' "$YELLOW" "$NC"; pause_for_enter ;;
            4)
                confirm_action "移除 SBX 调优参数？" || continue
                rm -f "$TCP_SYSCTL_CONF"; sysctl --system >/dev/null 2>&1 || true
                printf '%b[OK] 已恢复默认%b\n' "$GREEN" "$NC"; pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}

_run_remote_script() {
    local title="$1" url="$2"
    menu_header "$title"
    confirm_action "以 root 执行 ${url} 提供的第三方脚本（未验证完整性），继续？" || return 0
    local tmp
    tmp=$(mktemp /tmp/sbx_ext_XXXXXX) || return 1
    if curl -qfsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp" 2>/dev/null || wget -T 15 -t 1 -qO "$tmp" "$url" 2>/dev/null; then
        if [ -s "$tmp" ] && bash -n "$tmp"; then
            bash "$tmp" || printf '%b[!] 第三方脚本执行失败%b\n' "$RED" "$NC"
        else
            printf '%b[!] 下载内容为空或不符合 Bash 语法%b\n' "$RED" "$NC"
        fi
    else
        printf '%b[!] 下载失败%b\n' "$RED" "$NC"
    fi
    rm -f "$tmp"
    pause_for_enter
}

check_return_route() { _run_remote_script "BestTrace 回程路由测试" "https://besttrace.sh"; }
check_media_unlock() { _run_remote_script "流媒体与 IP 质量检测" "https://Check.Place"; }

manage_ufw() {
    while true; do
        menu_header "UFW 防火墙管理"
        if ! command -v ufw >/dev/null 2>&1; then
            printf '  %bUFW 未安装%b\n\n' "$YELLOW" "$NC"
            menu_single 1 "安装 UFW"
            menu_single 0 "返回"
            _read_menu_choice ins_opt
            [ "$ins_opt" = "1" ] || return 0
            case "$OS_FAMILY" in
                debian) apt-get update -y && apt-get install -y ufw ;;
                redhat) dnf install -y ufw 2>/dev/null || yum install -y ufw ;;
                alpine) apk add ufw ;;
                arch)   pacman -S --noconfirm ufw ;;
            esac
            pause_for_enter; continue
        fi
        local st
        st=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
        [ "$st" = "active" ] && st="${GREEN}已开启${NC}" || st="${RED}已关闭${NC}"
        printf "  %b状态:%b %b\n\n" "$CYAN" "$NC" "$st"
        menu_pair 1 "查看规则" 2 "放行端口"
        menu_pair 3 "删除规则" 4 "开启防火墙"
        menu_pair 5 "关闭防火墙" 6 "放行所有监听端口"
        menu_single 0 "返回"
        _read_menu_choice ufw_opt "> 选择 [0-6]: "
        case "$ufw_opt" in
            1) printf '\n'; ufw status numbered; pause_for_enter ;;
            2)
                local port proto
                read -rp "  放行端口: " port; port="${port// /}"
                [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                read -rp "  协议 (tcp/udp, 回车全放行): " proto; proto="${proto// /}"
                [ -n "$proto" ] && ufw allow "${port}/${proto}" || ufw allow "$port"
                pause_for_enter ;;
            3)
                ufw status numbered
                local r_num
                read -rp "  删除规则编号: " r_num; r_num="${r_num// /}"
                [[ "$r_num" =~ ^[0-9]+$ ]] && ufw --force delete "$r_num"
                pause_for_enter ;;
            4)
                local ssh_port
                ssh_port=$(ss -tlnp 2>/dev/null | grep -w sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
                [ -n "$ssh_port" ] || ssh_port=$(awk '/^Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
                ssh_port="${ssh_port:-22}"
                if confirm_action "启用 UFW (自动放行 SSH 端口 ${ssh_port})？" "y"; then
                    ufw allow "${ssh_port}/tcp" >/dev/null 2>&1 || true
                    ufw default deny incoming >/dev/null 2>&1 || true
                    ufw default allow outgoing >/dev/null 2>&1 || true
                    ufw --force enable
                    pause_for_enter
                fi ;;
            5) confirm_action "关闭 UFW？" && { ufw disable; pause_for_enter; } ;;
            6)
                confirm_action "放行本机所有监听端口？" || continue
                local p
                for p in $(ss -tlnu 2>/dev/null | awk 'NR>1{print $5}' | awk -F: '{print $NF}' | sort -nu); do
                    [[ "$p" =~ ^[0-9]+$ ]] && ufw allow "$p" >/dev/null 2>&1 && printf '  + 端口 %s\n' "$p"
                done
                pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}
