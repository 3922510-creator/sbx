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
    menu_header "系统信息总览"
    local os_info cpu_model cpu_cores cpu_freq virt_type cpu_usage mem_info swap_info disk_info load uptime_str tcp_count udp_count ip_data ip4 ip6 loc
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)
    [ -n "$os_info" ] || os_info="$(uname -s) $(uname -r)"
    cpu_model=$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d':' -f2 | sed 's/^ *//')
    [ -n "$cpu_model" ] || cpu_model="$(uname -m)"
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    cpu_freq=$(awk '/^cpu MHz/{printf "%.1fGHz\n", $4/1000; exit}' /proc/cpuinfo 2>/dev/null)
    virt_type=$(systemd-detect-virt 2>/dev/null || echo "none")
    [ "$virt_type" = "none" ] || [ -z "$virt_type" ] && virt_type="KVM / 物理机"

    cpu_usage=$(awk '{u=$2+$4; t=$2+$4+$5; if(NR==1){u1=u;t1=t;} else printf "%.0f\n",(($2+$4-u1)*100/(t-t1))}' \
      <(grep 'cpu ' /proc/stat) <(sleep 0.3; grep 'cpu ' /proc/stat) 2>/dev/null)
    mem_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%d/%dMB (%.0f%%)", $3, $2, ($3*100/$2)}')
    swap_info=$(free -m 2>/dev/null | awk 'NR==3{if($2==0){printf "未启用"} else {printf "%d/%dMB (%.0f%%)", $3, $2, ($3*100/$2)}}')
    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s/%s (%s)", $3, $2, $5}')
    load=$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null || echo "N/A")
    uptime_str=$(awk -F. '{d=int($1/86400);h=int(($1%86400)/3600);m=int(($1%3600)/60);if(d>0)printf "%d天 ",d;if(h>0)printf "%d时 ",h;printf "%d分",m}' /proc/uptime 2>/dev/null)
    tcp_count=$(ss -t -a 2>/dev/null | grep -c ESTAB || echo "0")
    udp_count=$(ss -u -a 2>/dev/null | grep -c UNCONN || echo "0")

    ip_data=$(_get_public_ip)
    ip4=$(echo "$ip_data" | cut -d'|' -f1)
    ip6=$(echo "$ip_data" | cut -d'|' -f2)
    loc=$(echo "$ip_data" | cut -d'|' -f3)

    printf "  %b系统:%b %s (%s · %s)\n" "$CYAN" "$NC" "$os_info" "$virt_type" "$(uname -m)"
    printf "  %bCPU :%b %s (%s核 %s) · 占用 %s%%\n" "$CYAN" "$NC" "$cpu_model" "$cpu_cores" "${cpu_freq:-}" "${cpu_usage:-0}"
    printf "  %b负载:%b %s  |  %b运行:%b %s\n" "$CYAN" "$NC" "$load" "$CYAN" "$NC" "$uptime_str"
    printf "  %b内存:%b %s  |  %bSwap:%b %s\n" "$CYAN" "$NC" "$mem_info" "$CYAN" "$NC" "$swap_info"
    printf "  %b硬盘:%b %s  |  %b连接:%b TCP %s / UDP %s\n" "$CYAN" "$NC" "$disk_info" "$CYAN" "$NC" "$tcp_count" "$udp_count"
    print_divider
    printf "  %bIPv4:%b %s %s\n" "$CYAN" "$NC" "${ip4:-无}" "${loc:+($loc)}"
    printf "  %bIPv6:%b %s\n" "$CYAN" "$NC" "${ip6:-无}"
    print_divider
    pause_for_enter
}

system_update() {
    menu_header "系统更新与组件安装"
    confirm_action "更新系统源并安装基础组件 (curl/wget/git/jq/socat/htop/unzip)？" || return 0
    local pkgs="curl wget git jq tar socat htop unzip ca-certificates iptables util-linux"
    case "$OS_FAMILY" in
        debian) export DEBIAN_FRONTEND=noninteractive; apt-get update -y && apt-get upgrade -y && apt-get install -y $pkgs ;;
        redhat) (command -v dnf >/dev/null 2>&1 && dnf update -y && dnf install -y $pkgs) || (yum update -y && yum install -y $pkgs) ;;
        alpine) apk update && apk upgrade && apk add --no-cache $pkgs ;;
        arch)   pacman -Syu --noconfirm && pacman -S --noconfirm $pkgs ;;
        *)      printf '%b[!] 暂不支持该发行版自动更新%b\n' "$YELLOW" "$NC" ;;
    esac
    printf '\n%b[OK] 系统更新完成%b\n' "$GREEN" "$NC"
    pause_for_enter
}

system_clean() {
    menu_header "系统垃圾清理"
    confirm_action "清理包缓存、无用依赖、过期日志与临时文件？" || return 0
    case "$OS_FAMILY" in
        debian) apt-get autoremove --purge -y; apt-get clean -y; apt-get autoclean -y ;;
        redhat) (command -v dnf >/dev/null 2>&1 && dnf autoremove -y && dnf clean all) || (yum autoremove -y && yum clean all) ;;
        alpine) apk cache clean; rm -rf /var/cache/apk/* ;;
    esac
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --rotate 2>/dev/null || true
        journalctl --vacuum-time=2d --vacuum-size=50M 2>/dev/null || true
    fi
    find /tmp /var/tmp -mindepth 1 -mtime +2 -delete 2>/dev/null || true
    printf '\n%b[OK] 清理完成%b\n' "$GREEN" "$NC"
    pause_for_enter
}

change_root_password() {
    menu_header "修改 Root 密码"
    local p1 p2
    read -rsp "  输入新 Root 密码 (不回显): " p1; printf '\n'
    [ -n "$p1" ] || { printf '%b[!] 密码不能为空%b\n' "$RED" "$NC"; pause_for_enter; return 0; }
    read -rsp "  再次确认新密码: " p2; printf '\n'
    [ "$p1" = "$p2" ] || { printf '%b[!] 两次输入不一致%b\n' "$RED" "$NC"; pause_for_enter; return 0; }
    if echo "root:${p1}" | chpasswd 2>/dev/null || printf '%s\n%s\n' "$p1" "$p1" | passwd root 2>/dev/null; then
        printf '\n%b[OK] Root 密码已更新%b\n' "$GREEN" "$NC"
    else
        printf '\n%b[!] 修改失败%b\n' "$RED" "$NC"
    fi
    pause_for_enter
}

_set_tz() {
    local tz="$1"
    if command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$tz" 2>/dev/null; then
        printf '%b[OK] 时区已设为 %s%b\n' "$GREEN" "$tz" "$NC"
    elif [ -e "/usr/share/zoneinfo/${tz}" ]; then
        ln -sf "/usr/share/zoneinfo/${tz}" /etc/localtime
        echo "$tz" > /etc/timezone 2>/dev/null || true
        printf '%b[OK] 时区已设为 %s%b\n' "$GREEN" "$tz" "$NC"
    else
        printf '%b[!] 无效时区: %s%b\n' "$RED" "$tz" "$NC"
    fi
}

manage_host_time() {
    while true; do
        menu_header "主机名与时区"
        local cur_host cur_tz
        cur_host=$(hostname 2>/dev/null || echo "未知")
        cur_tz=$(cat /etc/timezone 2>/dev/null || timedatectl 2>/dev/null | awk '/Time zone:/{print $3}' || echo "UTC")
        printf "  %b主机名:%b %s  |  %b时区:%b %s (%s)\n\n" "$CYAN" "$NC" "$cur_host" "$CYAN" "$NC" "$cur_tz" "$(date +'%H:%M:%S %Z')"
        menu_single 1 "修改主机名"
        menu_single 2 "设为北京时间 (Asia/Shanghai)"
        menu_single 3 "自定义时区"
        menu_single 0 "返回"
        _read_menu_choice ht_opt "> 选择 [0-3]: "
        case "$ht_opt" in
            1)
                local new_host
                read -rp "  新主机名: " new_host; new_host="${new_host// /}"
                [ -n "$new_host" ] && confirm_action "修改主机名为 ${new_host}？" || continue
                command -v hostnamectl >/dev/null 2>&1 && hostnamectl set-hostname "$new_host" || { echo "$new_host" > /etc/hostname; hostname "$new_host" 2>/dev/null || true; }
                [ -f /etc/hosts ] && { sed -i "/127.0.1.1/d" /etc/hosts 2>/dev/null || true; echo "127.0.1.1 $new_host" >> /etc/hosts; }
                printf '%b[OK] 主机名已设为 %s%b\n' "$GREEN" "$new_host" "$NC"; pause_for_enter ;;
            2) confirm_action "切换时区为 Asia/Shanghai？" && { _set_tz "Asia/Shanghai"; pause_for_enter; } ;;
            3)
                local new_tz
                read -rp "  目标时区 (如 UTC / America/New_York): " new_tz; new_tz="${new_tz// /}"
                [ -n "$new_tz" ] && { _set_tz "$new_tz"; pause_for_enter; } ;;
            0) return 0 ;;
        esac
    done
}
