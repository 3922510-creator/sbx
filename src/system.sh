# ==================== 系统维护模块 ====================

_get_public_ip() {
    local ip4="" ip6="" loc=""
    ip4=$(curl -s4m 2 https://api.ip.sb/ip 2>/dev/null || curl -s4m 2 https://ifconfig.me 2>/dev/null || echo "")
    ip6=$(curl -s6m 2 https://api.ip.sb/ip 2>/dev/null || echo "")
    if [ -n "$ip4" ]; then
        loc=$(curl -s4m 2 "https://api.ip.sb/geoip/${ip4}" 2>/dev/null | jq -r '.country // empty' 2>/dev/null || echo "")
        [ -n "$loc" ] || loc=$(curl -s4m 2 "https://ipinfo.io/country" 2>/dev/null || echo "")
    fi
    printf '%s|%s|%s' "$ip4" "$ip6" "$loc"
}

system_overview() {
    menu_header "系统信息与资源概览"
    printf '  %b正在收集系统实时状态...%b\n\n' "$DIM" "$NC"

    local os_info cpu_model cpu_cores cpu_freq virt_type
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
    [ -n "$os_info" ] || os_info="$(uname -s) $(uname -r)"

    cpu_model=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//')
    [ -n "$cpu_model" ] || cpu_model="$(uname -m)"
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    cpu_freq=$(awk '/^cpu MHz/{printf "%.1f GHz\n", $4/1000; exit}' /proc/cpuinfo 2>/dev/null)
    [ -n "$cpu_freq" ] || cpu_freq="N/A"

    virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    if [ "$virt_type" = "none" ] || [ -z "$virt_type" ]; then
        if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
            virt_type="KVM/独立虚拟化"
        else
            virt_type="物理机 / 容器"
        fi
    fi

    local cpu_usage
    cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if(NR==1){u1=u;t1=t;} else printf "%.0f\n",(($2+$4-u1)*100/(t-t1))}' \
      <(grep 'cpu ' /proc/stat) <(sleep 0.4; grep 'cpu ' /proc/stat) 2>/dev/null)
    [ -n "$cpu_usage" ] || cpu_usage="N/A"

    local mem_total mem_used mem_info swap_total swap_used swap_info disk_info
    mem_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%dM / %dM (%.0f%%)", $3, $2, ($3*100/$2)}')
    swap_info=$(free -m 2>/dev/null | awk 'NR==3{if($2==0){printf "未启用"} else {printf "%dM / %dM (%.0f%%)", $3, $2, ($3*100/$2)}}')
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')

    local load uptime_str
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
    uptime_str=$(awk -F. '{
        days=int($1/86400); hours=int(($1%86400)/3600); mins=int(($1%3600)/60);
        if(days>0) printf "%d天 ", days;
        if(hours>0) printf "%d小时 ", hours;
        printf "%d分钟", mins;
    }' /proc/uptime 2>/dev/null || echo "N/A")

    local tcp_count udp_count
    tcp_count=$(ss -t -a 2>/dev/null | grep -c ESTAB || echo "0")
    udp_count=$(ss -u -a 2>/dev/null | grep -c UNCONN || echo "0")

    local ip_data ip4 ip6 loc
    ip_data=$(_get_public_ip)
    ip4=$(echo "$ip_data" | cut -d'|' -f1)
    ip6=$(echo "$ip_data" | cut -d'|' -f2)
    loc=$(echo "$ip_data" | cut -d'|' -f3)

    printf "  %b系统环境:%b  %s\n" "$CYAN" "$NC" "$os_info"
    printf "  %b虚拟架构:%b  %s (%s)\n" "$CYAN" "$NC" "$virt_type" "$(uname -m)"
    printf "  %bCPU 信息:%b  %s (%s 核 · %s)\n" "$CYAN" "$NC" "$cpu_model" "$cpu_cores" "$cpu_freq"
    printf "  %bCPU 占用:%b  %s%%\n" "$CYAN" "$NC" "$cpu_usage"
    printf "  %b系统负载:%b  %s\n" "$CYAN" "$NC" "$load"
    printf "  %b内存占用:%b  %s\n" "$CYAN" "$NC" "$mem_info"
    printf "  %bSwap 占用:%b  %s\n" "$CYAN" "$NC" "$swap_info"
    printf "  %b根盘占用:%b  %s\n" "$CYAN" "$NC" "$disk_info"
    printf "  %b连接统计:%b  TCP(已建立): %s · UDP: %s\n" "$CYAN" "$NC" "$tcp_count" "$udp_count"
    printf "  %b开机时长:%b  %s\n" "$CYAN" "$NC" "$uptime_str"
    print_divider
    printf "  %bIPv4 地址:%b  %s %s\n" "$CYAN" "$NC" "${ip4:-无}" "${loc:+($loc)}"
    printf "  %bIPv6 地址:%b  %s\n" "$CYAN" "$NC" "${ip6:-无}"
    print_divider

    pause_for_enter
}

system_update() {
    menu_header "系统更新与基础组件安装"
    if ! confirm_action "更新系统包管理器源并安装常用基础组件？"; then return 0; fi

    printf '\n%b>>> 正在检测包管理器并执行系统更新...%b\n' "$CYAN" "$NC"
    case "$OS_FAMILY" in
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y && apt-get upgrade -y
            apt-get install -y curl wget git jq tar socat htop unzip ca-certificates iptables util-linux
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf update -y
                dnf install -y curl wget git jq tar socat htop unzip ca-certificates iptables util-linux
            else
                yum update -y
                yum install -y curl wget git jq tar socat htop unzip ca-certificates iptables util-linux
            fi
            ;;
        alpine)
            apk update && apk upgrade
            apk add --no-cache curl wget git jq tar socat htop unzip ca-certificates iptables util-linux
            ;;
        arch)
            pacman -Syu --noconfirm
            pacman -S --noconfirm curl wget git jq tar socat htop unzip ca-certificates iptables util-linux
            ;;
        *)
            printf '%b[!] 未知或暂不支持自动更新的 Linux 发行版。%b\n' "$YELLOW" "$NC"
            ;;
    esac

    printf '\n%b[成功] 系统更新与基础工具集已就绪。%b\n' "$GREEN" "$NC"
    pause_for_enter
}

system_clean() {
    menu_header "系统垃圾与日志清理"
    if ! confirm_action "清理系统包管理器缓存、废弃依赖与冗余日志？"; then return 0; fi

    printf '\n%b>>> 正在清理系统垃圾与无用依赖...%b\n' "$CYAN" "$NC"
    case "$OS_FAMILY" in
        debian)
            apt-get autoremove --purge -y
            apt-get clean -y
            apt-get autoclean -y
            ;;
        redhat)
            if command -v dnf >/dev/null 2>&1; then
                dnf autoremove -y
                dnf clean all
            else
                yum autoremove -y
                yum clean all
            fi
            ;;
        alpine)
            apk cache clean
            rm -rf /var/cache/apk/*
            ;;
    esac

    # 清理 systemd 日志
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-time=2d 2>/dev/null || true
        journalctl --vacuum-size=50M 2>/dev/null || true
    fi

    # 清理 /tmp 临时过期文件（>2天）
    find /tmp -mindepth 1 -mtime +2 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -mtime +2 -delete 2>/dev/null || true

    printf '\n%b[成功] 系统垃圾与日志清理完成！%b\n' "$GREEN" "$NC"
    pause_for_enter
}

change_root_password() {
    menu_header "修改 Root 用户密码"
    printf '  %b提示: 输入时字符不回显，请仔细输入。%b\n\n' "$YELLOW" "$NC"

    local p1 p2
    read -rsp "  请输入新的 Root 密码: " p1
    printf '\n'
    [ -n "$p1" ] || { printf '%b[!] 密码不能为空。%b\n' "$RED" "$NC"; pause_for_enter; return 0; }

    read -rsp "  请再次确认 Root 密码: " p2
    printf '\n'
    if [ "$p1" != "$p2" ]; then
        printf '%b[!] 两次密码输入不一致，已取消。%b\n' "$RED" "$NC"
        pause_for_enter
        return 0
    fi

    if echo "root:${p1}" | chpasswd 2>/dev/null || echo -e "${p1}\n${p1}" | passwd root 2>/dev/null; then
        printf '\n%b[成功] Root 密码已修改成功，请牢记新密码！%b\n' "$GREEN" "$NC"
    else
        printf '\n%b[错误] 修改 Root 密码失败。%b\n' "$RED" "$NC"
    fi
    pause_for_enter
}

manage_host_time() {
    while true; do
        menu_header "主机名与时区配置"
        local cur_host cur_tz cur_time
        cur_host=$(hostname 2>/dev/null || echo "未知")
        cur_tz=$(cat /etc/timezone 2>/dev/null || timedatectl 2>/dev/null | awk '/Time zone:/{print $3}' || echo "UTC")
        cur_time=$(date +"%Y-%m-%d %H:%M:%S %Z")

        printf "  %b当前主机名:%b  %s\n" "$CYAN" "$NC" "$cur_host"
        printf "  %b当前时区:  %b  %s (%s)\n\n" "$CYAN" "$NC" "$cur_tz" "$cur_time"

        menu_single 1 "修改系统主机名 (Hostname)"
        menu_single 2 "一键切换为中国标准时间 (Asia/Shanghai)"
        menu_single 3 "自定义切换系统时区"
        menu_single 0 "返回主菜单"

        _read_menu_choice ht_opt "> 请选择操作 [0-3]: "
        case "$ht_opt" in
            1)
                local new_host
                printf '\n'
                read -rp "  请输入新的主机名: " new_host
                new_host="${new_host// /}"
                [ -n "$new_host" ] || continue
                if confirm_action "修改系统主机名为: ${new_host}？"; then
                    if command -v hostnamectl >/dev/null 2>&1; then
                        hostnamectl set-hostname "$new_host"
                    else
                        echo "$new_host" > /etc/hostname
                        hostname "$new_host" 2>/dev/null || true
                    fi
                    # 同步 /etc/hosts 避免 sudo 报警
                    if [ -f /etc/hosts ]; then
                        sed -i "/127.0.1.1/d" /etc/hosts 2>/dev/null || true
                        echo "127.0.1.1 $new_host" >> /etc/hosts
                    fi
                    printf '%b[成功] 主机名已更新为: %s%b\n' "$GREEN" "$new_host" "$NC"
                    pause_for_enter
                fi
                ;;
            2)
                if confirm_action "将系统时区修改为 Asia/Shanghai (UTC+8)？"; then
                    if command -v timedatectl >/dev/null 2>&1; then
                        timedatectl set-timezone "Asia/Shanghai"
                    elif [ -e /usr/share/zoneinfo/Asia/Shanghai ]; then
                        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
                        echo "Asia/Shanghai" > /etc/timezone 2>/dev/null || true
                    fi
                    printf '%b[成功] 时区已更新为 Asia/Shanghai！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            3)
                local new_tz
                printf '\n'
                read -rp "  请输入目标时区 (如 UTC / America/New_York): " new_tz
                new_tz="${new_tz// /}"
                [ -n "$new_tz" ] || continue
                if command -v timedatectl >/dev/null 2>&1; then
                    if timedatectl set-timezone "$new_tz" 2>/dev/null; then
                        printf '%b[成功] 时区已更新为: %s%b\n' "$GREEN" "$new_tz" "$NC"
                    else
                        printf '%b[错误] 时区名称无效。%b\n' "$RED" "$NC"
                    fi
                elif [ -e "/usr/share/zoneinfo/${new_tz}" ]; then
                    ln -sf "/usr/share/zoneinfo/${new_tz}" /etc/localtime
                    echo "$new_tz" > /etc/timezone 2>/dev/null || true
                    printf '%b[成功] 时区已更新为: %s%b\n' "$GREEN" "$new_tz" "$NC"
                else
                    printf '%b[错误] 找不到时区文件。%b\n' "$RED" "$NC"
                fi
                pause_for_enter
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}
