# ==================== 网络优化与系统安全 ====================

# ---------- Swap 虚拟内存管理 ----------
manage_swap() {
    while true; do
        menu_header "Swap 虚拟内存管理"
        local swap_total swap_used swap_path
        swap_total=$(free -m 2>/dev/null | awk 'NR==3{print $2}')
        swap_used=$(free -m 2>/dev/null | awk 'NR==3{print $3}')
        swap_path=$(swapon --show=NAME --noheadings 2>/dev/null | head -1)

        printf "  %b当前 Swap 状态:%b " "$CYAN" "$NC"
        if [ -z "$swap_total" ] || [ "$swap_total" -eq 0 ]; then
            printf "%b未启用%b\n\n" "$YELLOW" "$NC"
        else
            printf "%b%s MB / %s MB (已用: %s MB)%b\n" "$GREEN" "$swap_used" "$swap_total" "$swap_used" "$NC"
            printf "  %b当前 Swap 文件:%b %s\n\n" "$CYAN" "$NC" "${swap_path:-分区}"
        fi

        menu_single 1 "创建 / 重设为 1GB Swap"
        menu_single 2 "创建 / 重设为 2GB Swap"
        menu_single 3 "创建 / 重设为 4GB Swap"
        menu_single 4 "自定义大小 (MB)"
        menu_single 5 "彻底关闭并删除 Swap"
        menu_single 0 "返回主菜单"

        _read_menu_choice swap_opt "> 请选择操作 [0-5]: "
        local mb_size=0
        case "$swap_opt" in
            1) mb_size=1024 ;;
            2) mb_size=2048 ;;
            3) mb_size=4096 ;;
            4)
                printf '\n'
                read -rp "  请输入 Swap 大小 (MB): " mb_size
                mb_size="${mb_size// /}"
                [[ "$mb_size" =~ ^[0-9]+$ ]] && [ "$mb_size" -ge 128 ] || {
                    printf '%b[!] 输入无效，大小至少为 128MB。%b\n' "$RED" "$NC"
                    pause_for_enter; continue;
                }
                ;;
            5)
                if confirm_action "彻底关闭并删除 /swapfile？"; then
                    swapoff -a 2>/dev/null || true
                    sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
                    rm -f /swapfile
                    printf '\n%b[成功] Swap 已安全停用并清理。%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                continue
                ;;
            0) return 0 ;;
            *) sleep 1; continue ;;
        esac

        if [ "$mb_size" -gt 0 ]; then
            if ! confirm_action "确认分配 ${mb_size} MB 虚拟内存？"; then continue; fi
            printf '\n%b>>> 正在分配 Swap 空间并格式化...%b\n' "$CYAN" "$NC"
            swapoff -a 2>/dev/null || true
            sed -i '/swapfile/d' /etc/fstab 2>/dev/null || true
            rm -f /swapfile

            if ! fallocate -l "${mb_size}M" /swapfile 2>/dev/null; then
                dd if=/dev/zero of=/swapfile bs=1M count="$mb_size" status=progress
            fi
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1

            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile swap swap defaults 0 0' >> /etc/fstab
            fi
            sysctl -w vm.swappiness=20 >/dev/null 2>&1 || true

            printf '\n%b[成功] Swap 已成功分配并设为开机自启！%b\n' "$GREEN" "$NC"
            pause_for_enter
        fi
    done
}

# ---------- DNS 优化与设置 ----------
_apply_dns() {
    local d1="$1" d2="$2"
    local bak="/etc/resolv.conf.sbx_bak"
    [ -f "$bak" ] || cp -p /etc/resolv.conf "$bak" 2>/dev/null || true

    # 解除不可修改属性（若有）
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf <<EOF
nameserver ${d1}
nameserver ${d2}
options timeout:2 attempts:3 rotate
EOF
    printf '\n%b[成功] DNS 已更新为: %s, %s%b\n' "$GREEN" "$d1" "$d2" "$NC"
}

optimize_dns() {
    while true; do
        menu_header "DNS 解析优化与修改"
        local cur_dns
        cur_dns=$(awk '/nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
        printf "  %b当前系统 DNS:%b %s\n\n" "$CYAN" "$NC" "${cur_dns:-无}"

        menu_single 1 "设置为国际公共 DNS (Cloudflare 1.1.1.1 + Google 8.8.8.8)"
        menu_single 2 "设置为国内主流 DNS (阿里 223.5.5.5 + 腾讯 119.29.29.29)"
        menu_single 3 "自定义输入 DNS IP"
        menu_single 4 "还原修改前的 DNS 备份"
        menu_single 0 "返回主菜单"

        _read_menu_choice dns_opt "> 请选择操作 [0-4]: "
        case "$dns_opt" in
            1) _apply_dns "1.1.1.1" "8.8.8.8"; pause_for_enter ;;
            2) _apply_dns "223.5.5.5" "119.29.29.29"; pause_for_enter ;;
            3)
                local d1 d2
                printf '\n'
                read -rp "  请输入首选 DNS (IPv4): " d1
                read -rp "  请输入备选 DNS (IPv4, 可留空): " d2
                d1="${d1// /}"; d2="${d2// /}"
                [ -n "$d1" ] || continue
                [ -n "$d2" ] || d2="$d1"
                _apply_dns "$d1" "$d2"
                pause_for_enter
                ;;
            4)
                if [ -f /etc/resolv.conf.sbx_bak ]; then
                    chattr -i /etc/resolv.conf 2>/dev/null || true
                    cp -pf /etc/resolv.conf.sbx_bak /etc/resolv.conf
                    printf '\n%b[成功] 已从备份还原 /etc/resolv.conf！%b\n' "$GREEN" "$NC"
                else
                    printf '\n%b[!] 未找到历史备份文件。%b\n' "$YELLOW" "$NC"
                fi
                pause_for_enter
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------- TCP 参数调优与 BBR ----------
manage_tcp_bbr() {
    while true; do
        menu_header "TCP 调优与 BBR 拥塞控制"
        local cur_cc cur_qdisc
        cur_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        cur_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")

        printf "  %b当前拥塞算法:%b %s\n" "$CYAN" "$NC" "$cur_cc"
        printf "  %b当前队列规则:%b %s\n" "$CYAN" "$NC" "$cur_qdisc"
        if [ -f "$TCP_SYSCTL_CONF" ]; then
            printf "  %bSBX 调优状态:%b %b已应用%b\n\n" "$CYAN" "$NC" "$GREEN" "$NC"
        else
            printf "  %bSBX 调优状态:%b %b未应用%b\n\n" "$CYAN" "$NC" "$DIM" "$NC"
        fi

        menu_single 1 "一键启用 原生 BBR + FQ 加速"
        menu_single 2 "一键应用 TCP 缓冲区与大并发高吞吐调优"
        menu_single 3 "查看当前内核调优参数文件"
        menu_single 4 "还原为系统默认 TCP 参数"
        menu_single 0 "返回主菜单"

        _read_menu_choice tcp_opt "> 请选择操作 [0-4]: "
        case "$tcp_opt" in
            1)
                if confirm_action "启用 Linux 原生 BBR 拥塞控制？"; then
                    modprobe tcp_bbr 2>/dev/null || true
                    sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1 || true
                    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || true
                    # 持久化
                    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null || true
                    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null || true
                    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
                    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
                    printf '\n%b[成功] 原生 BBR + FQ 已成功启用并持久化！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            2)
                if confirm_action "应用 TCP 高并发、低延迟与大缓冲区参数？"; then
                    cat > "$TCP_SYSCTL_CONF" <<'EOF'
# SBX 网络性能优化配置
fs.file-max = 1000000
fs.inotify.max_user_instances = 8192
net.core.default_qdisc = fq
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 65536
net.core.wmem_default = 65536
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
                    printf '\n%b[成功] TCP 高吞吐调优参数已应用！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            3)
                if [ -f "$TCP_SYSCTL_CONF" ]; then
                    printf '\n%b--- [%s] 内容 ---%b\n' "$CYAN" "$TCP_SYSCTL_CONF" "$NC"
                    cat "$TCP_SYSCTL_CONF"
                else
                    printf '\n%b[!] 尚未生成调优参数文件。%b\n' "$YELLOW" "$NC"
                fi
                pause_for_enter
                ;;
            4)
                if confirm_action "移除 SBX 调优文件并重置为系统默认配置？"; then
                    rm -f "$TCP_SYSCTL_CONF"
                    sysctl --system >/dev/null 2>&1 || true
                    printf '\n%b[成功] 已恢复系统默认参数。%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------- 回程线路检测 ----------
check_return_route() {
    menu_header "回程线路延迟与路由测试"
    printf '  %b测试国内三大运营商主要骨干网回程延迟与连通性...%b\n\n' "$DIM" "$NC"

    # 目标列表：名称|IP|运营商
    local targets=(
        "北京电信 163|219.141.136.12|电信"
        "上海电信 CN2|58.32.0.1|电信CN2"
        "广州电信|14.215.116.1|电信"
        "北京联通 169|202.106.0.20|联通"
        "上海联通 9929|210.13.66.238|联通A网"
        "广州联通|210.21.196.6|联通"
        "北京移动 CMI|211.136.25.153|移动"
        "上海移动|221.183.55.0|移动"
        "广州移动|120.196.165.7|移动"
        "北京教育网|202.112.0.46|教育网"
    )

    printf "  %-16s %-18s %-10s %s\n" "目标节点" "目标 IP" "丢包率" "平均延迟 (RTT)"
    print_divider

    local item name ip isp stat loss avg
    for item in "${targets[@]}"; do
        IFS='|' read -r name ip isp <<< "$item"
        stat=$(ping -c 3 -W 1 "$ip" 2>/dev/null)
        if [ $? -eq 0 ]; then
            loss=$(echo "$stat" | grep -o '[0-9]*% packet loss' | cut -d'%' -f1 || echo "0")
            avg=$(echo "$stat" | awk -F'/' 'END{printf "%.1f ms", $5}' 2>/dev/null)
            [ -n "$avg" ] || avg="N/A"
            printf "  %-16s %-18s %-10s %b%s%b\n" "$name" "$ip" "${loss}%" "$GREEN" "$avg" "$NC"
        else
            printf "  %-16s %-18s %-10s %b超时/不可达%b\n" "$name" "$ip" "100%" "$RED" "$NC"
        fi
    done
    print_divider

    pause_for_enter
}

# ---------- UFW 防火墙管理 ----------
manage_ufw() {
    while true; do
        menu_header "UFW 防火墙端口管理"
        if ! command -v ufw >/dev/null 2>&1; then
            printf '  %b系统尚未安装 UFW 防火墙。%b\n\n' "$YELLOW" "$NC"
            menu_single 1 "一键安装 UFW 防火墙"
            menu_single 0 "返回主菜单"
            _read_menu_choice ins_opt
            if [ "$ins_opt" = "1" ]; then
                case "$OS_FAMILY" in
                    debian) apt-get update -y && apt-get install -y ufw ;;
                    redhat) dnf install -y ufw 2>/dev/null || yum install -y ufw ;;
                    alpine) apk add ufw ;;
                    arch) pacman -S --noconfirm ufw ;;
                esac
                pause_for_enter
            else
                return 0
            fi
            continue
        fi

        local ufw_status
        ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
        printf "  %b当前 UFW 状态:%b " "$CYAN" "$NC"
        if [ "$ufw_status" = "active" ]; then
            printf "%b已激活 (运行中)%b\n\n" "$GREEN" "$NC"
        else
            printf "%b未激活 (已关闭)%b\n\n" "$RED" "$NC"
        fi

        menu_single 1 "查看当前规则列表与端口"
        menu_single 2 "放行指定端口 (TCP / UDP)"
        menu_single 3 "删除指定编号规则"
        menu_single 4 "开启防火墙 (自动放行 SSH 端口防失联)"
        menu_single 5 "彻底关闭防火墙"
        menu_single 6 "一键仅放行当前正在监听的公开端口"
        menu_single 0 "返回主菜单"

        _read_menu_choice ufw_opt "> 请选择操作 [0-6]: "
        case "$ufw_opt" in
            1)
                printf '\n%b>>> UFW 当前规则列表：%b\n' "$CYAN" "$NC"
                ufw status numbered
                pause_for_enter
                ;;
            2)
                local port proto
                printf '\n'
                read -rp "  请输入要放行的端口: " port
                port="${port// /}"
                [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
                    printf '%b[!] 端口号不合法。%b\n' "$RED" "$NC"; pause_for_enter; continue;
                }
                read -rp "  请输入协议 (tcp/udp，直接回车代表两者全部放行): " proto
                proto="${proto// /}"
                if [ -n "$proto" ]; then
                    ufw allow "${port}/${proto}"
                else
                    ufw allow "$port"
                fi
                printf '%b[成功] 端口 %s 已放行！%b\n' "$GREEN" "$port" "$NC"
                pause_for_enter
                ;;
            3)
                printf '\n'
                ufw status numbered
                local r_num
                read -rp "  请输入要删除的【规则编号】: " r_num
                r_num="${r_num// /}"
                [[ "$r_num" =~ ^[0-9]+$ ]] || { printf '%b[!] 编号必须为纯数字。%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                ufw --force delete "$r_num"
                printf '%b[成功] 规则 %s 已删除！%b\n' "$GREEN" "$r_num" "$NC"
                pause_for_enter
                ;;
            4)
                # 关键防失联：探测当前 ssh 端口
                local ssh_port
                ssh_port=$(ss -tlnp 2>/dev/null | grep -w sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
                [ -n "$ssh_port" ] || ssh_port=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
                ssh_port="${ssh_port:-22}"

                if confirm_action "启用 UFW 防火墙？（将自动放行 SSH 端口: ${ssh_port} 保证不断连）" "y"; then
                    ufw allow "$ssh_port"/tcp >/dev/null 2>&1 || true
                    ufw default deny incoming >/dev/null 2>&1 || true
                    ufw default allow outgoing >/dev/null 2>&1 || true
                    ufw --force enable
                    printf '%b[成功] UFW 防火墙已成功开启！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            5)
                if confirm_action "关闭 UFW 防火墙？"; then
                    ufw disable
                    printf '%b[成功] UFW 防火墙已关闭。%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            6)
                if confirm_action "自动放行当前本机所有已监听的公开端口？"; then
                    local p
                    for p in $(ss -tlnu 2>/dev/null | awk 'NR>1{print $5}' | awk -F: '{print $NF}' | sort -nu); do
                        [[ "$p" =~ ^[0-9]+$ ]] || continue
                        ufw allow "$p" >/dev/null 2>&1 || true
                        printf '  放行端口: %s\n' "$p"
                    done
                    printf '%b[成功] 所有在听端口放行完成！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}
