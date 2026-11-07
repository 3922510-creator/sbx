#!/usr/bin/env bash
# =====================================================================
# 项目名称: SBX (Sing-box & Linux VPS 管理面板)
# 版本: v5.0.0
# 快捷指令: sbx
# =====================================================================
set -o pipefail
SBX_VERSION="v5.0.0"

# ---------- ANSI 颜色与修饰 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ---------- 路径与常量 ----------
SBX_ROOT="/etc/sbx"
CONFIG_FILE="${SBX_ROOT}/config.json"
META_DIR="${SBX_ROOT}/.meta"
STATE_FILE="${META_DIR}/state.json"
BACKUP_DIR="${SBX_ROOT}/backups"
LOG_FILE="/var/log/sbx.log"
BIN_FILE="/usr/local/bin/sing-box"
SHORTCUT_PATH="/usr/local/bin/sbx"
SERVICE_SYSTEMD="/etc/systemd/system/sbx.service"
SERVICE_OPENRC="/etc/init.d/sbx"
TCP_SYSCTL_CONF="/etc/sysctl.d/99-sbx-tcp.conf"
LOCK_FILE="/run/sbx.lock"

OS_FAMILY="unknown"
INIT_SYS="none"

# ---------- 平台识别 ----------
platform_detect() {
    local ID='' ID_LIKE=''
    [ ! -r /etc/os-release ] || . /etc/os-release
    case "$ID $ID_LIKE" in
        *alpine*) OS_FAMILY="alpine" ;;
        *debian*|*ubuntu*) OS_FAMILY="debian" ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*amzn*) OS_FAMILY="redhat" ;;
        *arch*|*manjaro*) OS_FAMILY="arch" ;;
        *) OS_FAMILY="linux" ;;
    esac
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYS="openrc"
    else
        INIT_SYS="none"
    fi
}

# ---------- 终端与排版工具 ----------
clear_screen() {
    if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; then
        clear
    else
        printf '\n'
    fi
}

get_term_width() {
    local w="${COLUMNS:-0}"
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    if [ "$w" -eq 0 ]; then
        w=$(stty size 2>/dev/null | awk '{print $2}') || w=''
    fi
    case "$w" in ''|*[!0-9]*) w=62 ;; esac
    [ "$w" -ge 46 ] || w=46
    [ "$w" -le 72 ] || w=72
    printf '%s' "$w"
}

print_divider() {
    local w line="" i=0
    w=$(get_term_width)
    while [ "$i" -lt "$w" ]; do
        line="${line}─"
        i=$((i + 1))
    done
    printf '%b%s%b\n' "${DIM}${CYAN}" "$line" "$NC"
}

print_center() {
    local text="$1" color="${2:-$NC}"
    local clean_text w pad_left i=0
    clean_text=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    w=$(get_term_width)
    pad_left=$(( (w - ${#clean_text}) / 2 ))
    [ "$pad_left" -gt 0 ] || pad_left=0
    printf '%*s%b%s%b\n' "$pad_left" '' "$color" "$text" "$NC"
}

pause_for_enter() {
    printf '\n'
    read -rp "  按回车键继续..." _ || return 0
}

confirm_action() {
    local prompt="$1" default="${2:-n}" answer
    printf '\n%b%s%b\n' "$YELLOW" "$prompt" "$NC"
    if [ "$default" = "y" ]; then
        read -rp "确认执行？回复 y / n [默认 y]: " answer || return 1
        answer="${answer:-y}"
    else
        read -rp "确认执行？回复 y / n [默认 n]: " answer || return 1
        answer="${answer:-n}"
    fi
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# 双列菜单输出（参考 vpsbox 布局，字符精确对齐）
menu_pair() {
    local num1="$1" txt1="$2" num2="$3" txt2="$4"
    local col_w=28
    # 左列
    local left_str right_str
    left_str=$(printf "  %b%2s.%b %s" "$GREEN" "$num1" "$NC" "$txt1")
    # 计算左列可见字符宽度以做补齐
    local clean_left pad
    clean_left=$(printf "  %2s. %s" "$num1" "$txt1")
    pad=$((col_w - ${#clean_left}))
    [ "$pad" -gt 0 ] || pad=1

    if [ -n "$num2" ]; then
        right_str=$(printf "%b%2s.%b %s" "$GREEN" "$num2" "$NC" "$txt2")
        printf "%s%*s%s\n" "$left_str" "$pad" "" "$right_str"
    else
        printf "%s\n" "$left_str"
    fi
}

menu_single() {
    local num="$1" txt="$2"
    printf "  %b%2s.%b %s\n" "$GREEN" "$num" "$NC" "$txt"
}

menu_header() {
    clear_screen
    print_divider
    print_center "$1" "$PURPLE$BOLD"
    print_divider
    printf '\n'
}

_read_menu_choice() {
    local var_name="${1:-OPTION}" prompt="${2:-> 请选择: }"
    printf '\n%b%s%b' "$CYAN" "$prompt" "$NC"
    read -r REPLY || REPLY=0
    REPLY="${REPLY// /}"
    eval "$var_name=\"\$REPLY\""
}

# ---------- 并发锁机制 ----------
acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    [ "${SBX_LOCKED:-0}" = 1 ] && return 0
    exec 210>"$LOCK_FILE" || return 1
    flock -n 210 || {
        printf '%b[!] 另一个 sbx 实例正在执行操作，请稍候。%b\n' "$RED" "$NC" >&2
        return 1
    }
    SBX_LOCKED=1
}

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

# ---------- BestTrace 回程线路路由测试 ----------
check_return_route() {
    menu_header "BestTrace 回程线路路由测试"
    printf '  %b测试国内四大骨干网 (电信/联通/移动/教育网) 的回程路由与线路质量...%b\n\n' "$CYAN" "$NC"
    if ! confirm_action "从 besttrace.sh 下载并执行回程路由测试？" "y"; then return 0; fi

    printf '\n%b>>> 正在启动 BestTrace 回程测试引擎...%b\n\n' "$CYAN" "$NC"
    local bt_tmp
    bt_tmp=$(mktemp /tmp/sbx_bt_XXXXXX) || { printf '%b[错误] 无法创建临时文件。%b\n' "$RED" "$NC"; pause_for_enter; return; }
    if wget -qO- https://besttrace.sh -O "$bt_tmp" 2>/dev/null || curl -fsSL --connect-timeout 10 https://besttrace.sh -o "$bt_tmp"; then
        if grep -Eq '^#!/|(^|[[:space:]])(bash|sh)[[:space:]]' "$bt_tmp"; then
            bash "$bt_tmp"
        else
            printf '%b[错误] 脚本内容校验失败。%b\n' "$RED" "$NC"
        fi
    else
        printf '%b[错误] 下载 besttrace.sh 失败，请检查网络连通性。%b\n' "$RED" "$NC"
    fi
    rm -f "$bt_tmp"
    pause_for_enter
}

# ---------- 流媒体与 IP 质量检测 ----------
check_media_unlock() {
    menu_header "流媒体解锁与 IP 质量检测"
    printf '  %b启动权威流媒体与 IP 解锁检测引擎 (Check.Place)...%b\n\n' "$CYAN" "$NC"
    if ! confirm_action "下载并执行流媒体解锁测试脚本？" "y"; then return 0; fi

    printf '\n%b>>> 正在启动检测引擎...%b\n\n' "$CYAN" "$NC"
    local media_tmp
    media_tmp=$(mktemp /tmp/sbx_media_XXXXXX) || { printf '%b[错误] 无法创建临时文件。%b\n' "$RED" "$NC"; pause_for_enter; return; }
    if curl -fsSL --connect-timeout 10 --max-time 60 https://Check.Place -o "$media_tmp" 2>/dev/null || wget -qO- https://Check.Place -O "$media_tmp" 2>/dev/null; then
        if grep -Eq '^#!/|(^|[[:space:]])(bash|sh)[[:space:]]' "$media_tmp"; then
            bash "$media_tmp"
        else
            printf '%b[错误] 检测脚本内容校验失败。%b\n' "$RED" "$NC"
        fi
    else
        printf '%b[错误] 下载检测脚本失败，请检查网络出墙连通性。%b\n' "$RED" "$NC"
    fi
    rm -f "$media_tmp"
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

# ==================== Sing-box 核心与服务控制 ====================

ensure_dirs() {
    mkdir -p "$SBX_ROOT" "$META_DIR" "$BACKUP_DIR"
    chmod 700 "$SBX_ROOT" "$META_DIR" "$BACKUP_DIR"
}

sbx_service_status() {
    if [ ! -f "$SERVICE_SYSTEMD" ] && [ ! -f "$SERVICE_OPENRC" ]; then
        printf '%b未部署%b' "$DIM" "$NC"
        return 0
    fi
    if [ "$INIT_SYS" = "systemd" ]; then
        if systemctl is-active --quiet sbx.service 2>/dev/null; then
            printf '%b运行中%b' "$GREEN" "$NC"
        else
            printf '%b已停止%b' "$RED" "$NC"
        fi
    elif [ "$INIT_SYS" = "openrc" ]; then
        if rc-service sbx status 2>/dev/null | grep -q 'started'; then
            printf '%b运行中%b' "$GREEN" "$NC"
        else
            printf '%b已停止%b' "$RED" "$NC"
        fi
    else
        printf '%b未知%b' "$YELLOW" "$NC"
    fi
}

install_singbox_bin() {
    if [ -x "$BIN_FILE" ]; then
        printf 'Sing-box 核心已存在: %s\n' "$("$BIN_FILE" version 2>/dev/null | head -1)"
        return 0
    fi

    printf '%b>>> 正在安装 Sing-box 官方最新核心...%b\n' "$CYAN" "$NC"
    local arch uname_m
    uname_m=$(uname -m)
    case "$uname_m" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        *) printf '%b[!] 不支持的 CPU 架构: %s%b\n' "$RED" "$uname_m" "$NC"; return 1 ;;
    esac

    local tag url tmp_dir
    tag=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | cut -d'"' -f4)
    [ -n "$tag" ] || tag="v1.10.7"
    local ver="${tag#v}"

    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp_dir=$(mktemp -d /tmp/sbx_core_XXXXXX)
    printf '正在下载 %s ...\n' "$url"
    if curl -fsSL --connect-timeout 10 -o "${tmp_dir}/sb.tar.gz" "$url"; then
        tar -xzf "${tmp_dir}/sb.tar.gz" -C "$tmp_dir"
        local found_bin
        found_bin=$(find "$tmp_dir" -type f -name "sing-box" | head -1)
        if [ -n "$found_bin" ]; then
            install -m 755 "$found_bin" "$BIN_FILE"
            rm -rf "$tmp_dir"
            printf '%b[成功] Sing-box 核心安装完成: %s%b\n' "$GREEN" "$("$BIN_FILE" version | head -1)" "$NC"
            return 0
        fi
    fi
    rm -rf "$tmp_dir"
    printf '%b[错误] 下载或安装 Sing-box 核心失败。%b\n' "$RED" "$NC"
    return 1
}

deploy_sbx_service() {
    if [ "$INIT_SYS" = "systemd" ]; then
        cat > "$SERVICE_SYSTEMD" <<EOF
[Unit]
Description=Sing-box Service (Managed by SBX)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${BIN_FILE} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable sbx.service >/dev/null 2>&1 || true
    elif [ "$INIT_SYS" = "openrc" ]; then
        cat > "$SERVICE_OPENRC" <<EOF
#!/sbin/openrc-run
description="Sing-box Service (SBX)"
command="${BIN_FILE}"
command_args="run -c ${CONFIG_FILE}"
command_background="yes"
pidfile="/run/sbx.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after firewall
}
EOF
        chmod 755 "$SERVICE_OPENRC"
        rc-update add sbx default >/dev/null 2>&1 || true
    fi
}

init_sbx_config() {
    ensure_dirs
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" <<'EOF'
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  }
}
EOF
    fi
    if [ ! -f "$STATE_FILE" ]; then
        echo '{"format": 5, "nodes": {}}' > "$STATE_FILE"
    fi
}

sbx_backup_config() {
    ensure_dirs
    [ -f "$CONFIG_FILE" ] || return 0
    local ts
    ts=$(date +"%Y%m%d_%H%M%S")
    cp -pf "$CONFIG_FILE" "${BACKUP_DIR}/config_${ts}.json" 2>/dev/null || true
    # 最多保留 10 个备份
    local old_baks
    old_baks=$(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null | tail -n +11)
    if [ -n "$old_baks" ]; then
        rm -f $old_baks 2>/dev/null || true
    fi
}

sbx_check_config() {
    if [ ! -x "$BIN_FILE" ]; then return 0; fi
    "$BIN_FILE" check -c "$CONFIG_FILE" >/dev/null 2>&1
}

# 统一安全写入与核心预检函数：
# 1. 只有 candidate 通过 sing-box check，才允许覆盖 CONFIG_FILE
# 2. 预检不通过时，打印完整错误、清除临时文件，原配置 100% 不动
# 3. 覆盖后启动，若服务异常拉起失败，自动回滚上一次备份
sbx_apply_config_safe() {
    local candidate="$1"
    if [ ! -s "$candidate" ]; then
        printf '%b[错误] 待应用配置文件为空。%b\n' "$RED" "$NC"
        rm -f "$candidate"
        return 1
    fi

    # 1. 核心预检
    local check_err
    if ! check_err=$("$BIN_FILE" check -c "$candidate" 2>&1); then
        printf '\n%b[核心预检失败] 节点配置未通过 Sing-box 核心校验，已拒绝写入，原配置未做任何修改：%b\n' "$RED$BOLD" "$NC"
        printf '%b%s%b\n' "$YELLOW" "$check_err" "$NC"
        rm -f "$candidate"
        return 1
    fi

    # 2. 备份原配置
    sbx_backup_config

    # 3. 原子替换
    mv -f "$candidate" "$CONFIG_FILE"

    # 4. 重启服务
    sbx_svc_action restart >/dev/null 2>&1 || true

    # 5. 服务拉起校验（若拉起失败，自动回滚最近一次备份）
    sleep 0.5
    if [ "$INIT_SYS" = "systemd" ] && ! systemctl is-active --quiet sbx.service 2>/dev/null; then
        local latest_bak
        latest_bak=$(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            printf '\n%b[警告] 服务启动异常，正在自动回滚至上一版本配置...%b\n' "$RED" "$NC"
            cp -pf "$latest_bak" "$CONFIG_FILE"
            sbx_svc_action restart >/dev/null 2>&1 || true
        fi
        return 1
    fi

    return 0
}

sbx_svc_action() {
    local act="$1"
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl "$act" sbx.service
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-service sbx "$act"
    fi
}

manage_service() {
    while true; do
        menu_header "Sing-box 核心与服务维护"
        printf "  %b服务运行状态:%b  %b\n" "$CYAN" "$NC" "$(sbx_service_status)"
        printf "  %b配置文件路径:%b  %s\n" "$CYAN" "$NC" "$CONFIG_FILE"
        printf "  %b核心程序路径:%b  %s\n\n" "$CYAN" "$NC" "$BIN_FILE"

        menu_single 1 "启动 sing-box (sbx) 服务"
        menu_single 2 "停止 sing-box (sbx) 服务"
        menu_single 3 "重启 sing-box (sbx) 服务"
        menu_single 4 "查看实时运行日志"
        menu_single 5 "校验当前配置文件完整性"
        menu_single 6 "从历史备份中回滚配置"
        menu_single 7 "更新 / 重装 Sing-box 核心程序"
        menu_single 0 "返回主菜单"

        _read_menu_choice svc_opt "> 请选择操作 [0-7]: "
        case "$svc_opt" in
            1) sbx_svc_action start; pause_for_enter ;;
            2) sbx_svc_action stop; pause_for_enter ;;
            3) sbx_svc_action restart; pause_for_enter ;;
            4)
                printf '\n%b>>> 最近 30 行服务日志 (Ctrl+C 退出)：%b\n' "$CYAN" "$NC"
                if [ "$INIT_SYS" = "systemd" ]; then
                    journalctl -u sbx.service -n 30 --no-pager
                else
                    tail -n 30 "$LOG_FILE" 2>/dev/null || echo "暂无日志。"
                fi
                pause_for_enter
                ;;
            5)
                printf '\n'
                if "$BIN_FILE" check -c "$CONFIG_FILE"; then
                    printf '\n%b[成功] 配置文件校验完全通过！%b\n' "$GREEN" "$NC"
                else
                    printf '\n%b[错误] 配置文件存在语法或参数错误！%b\n' "$RED" "$NC"
                fi
                pause_for_enter
                ;;
            6)
                local baks choice i=1 b_list=()
                while IFS= read -r f; do
                    [ -n "$f" ] || continue
                    b_list+=("$f")
                done < <(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null)

                if [ ${#b_list[@]} -eq 0 ]; then
                    printf '\n%b[!] 暂无可用历史备份。%b\n' "$YELLOW" "$NC"
                    pause_for_enter
                    continue
                fi

                printf '\n%b历史备份列表：%b\n' "$CYAN" "$NC"
                for f in "${b_list[@]}"; do
                    printf "  %b%d)%b %s\n" "$GREEN" "$i" "$NC" "$(basename "$f")"
                    i=$((i + 1))
                done
                printf '\n'
                read -rp "  请选择要恢复的备份编号: " choice
                choice="${choice// /}"
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#b_list[@]}" ]; then
                    local target="${b_list[$((choice - 1))]}"
                    if confirm_action "从 $(basename "$target") 恢复配置？"; then
                        cp -pf "$target" "$CONFIG_FILE"
                        sbx_svc_action restart >/dev/null 2>&1 || true
                        printf '%b[成功] 配置已还原并重启服务！%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi
                ;;
            7)
                rm -f "$BIN_FILE"
                install_singbox_bin
                pause_for_enter
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ==================== VLESS-Reality 节点管理 ====================

_find_available_port() {
    local p="${1:-443}"
    while true; do
        if ! ss -tlnu 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | grep -wq "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
        [ "$p" -le 65535 ] || break
    done
    echo "4433"
}

_generate_reality_keys() {
    local out
    out=$("$BIN_FILE" generate reality-keypair 2>/dev/null)
    local priv pub
    priv=$(echo "$out" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
    pub=$(echo "$out" | awk '/PublicKey:/{print $2}' | tr -d '\r')
    printf '%s|%s' "$priv" "$pub"
}

add_reality_node() {
    menu_header "搭建 / 添加 VLESS-Reality 节点"
    acquire_lock || return 1
    install_singbox_bin || return 1
    init_sbx_config
    deploy_sbx_service

    printf '  %b[1/5] 设置节点端口%b\n' "$CYAN" "$NC"
    local rec_port port
    rec_port=$(_find_available_port 443)
    read -rp "  请输入监听端口 [默认 ${rec_port}]: " port
    port="${port// /}"
    port="${port:-$rec_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        printf '%b[!] 端口号不合法。%b\n' "$RED" "$NC"; pause_for_enter; return 1;
    }

    printf '\n  %b[2/5] 设置伪装域名 (SNI)%b\n' "$CYAN" "$NC"
    printf '  常用推荐: 1) addons.mozilla.org  2) gateway.icloud.com  3) www.microsoft.com\n'
    local sni sni_opt
    read -rp "  请选择或输入 SNI [直接回车默认 addons.mozilla.org]: " sni_opt
    sni_opt="${sni_opt// /}"
    case "$sni_opt" in
        1) sni="addons.mozilla.org" ;;
        2) sni="gateway.icloud.com" ;;
        3) sni="www.microsoft.com" ;;
        "") sni="addons.mozilla.org" ;;
        *) sni="$sni_opt" ;;
    esac

    printf '\n  %b[3/5] 生成安全密钥与认证凭据...%b\n' "$CYAN" "$NC"
    local uuid keys priv_key pub_key short_id tag
    uuid=$("$BIN_FILE" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
    keys=$(_generate_reality_keys)
    priv_key=$(echo "$keys" | cut -d'|' -f1)
    pub_key=$(echo "$keys" | cut -d'|' -f2)
    short_id=$(openssl rand -hex 8 2>/dev/null || echo "1a2b3c4d5e6f7a8b")
    tag="vless-reality-${port}"

    printf '\n  %b[4/5] 设置节点备注名称%b\n' "$CYAN" "$NC"
    local name
    read -rp "  请输入节点备注名称 [默认 Reality-${port}]: " name
    name="${name// /}"
    name="${name:-Reality-${port}}"

    # 写入配置并交由核心预检引擎安全应用
    local tmp_conf
    tmp_conf=$(mktemp /tmp/sbx_conf_XXXXXX)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg sni "$sni" \
       --arg priv "$priv_key" \
       --arg sid "$short_id" \
       '.inbounds = [.inbounds[] | select(.tag != $tag)] + [{
          "type": "vless",
          "tag": $tag,
          "listen": "::",
          "listen_port": $port,
          "tcp_fast_open": true,
          "users": [{
            "uuid": $uuid,
            "flow": "xtls-rprx-vision"
          }],
          "tls": {
            "enabled": true,
            "server_name": $sni,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $sni,
                "server_port": 443
              },
              "private_key": $priv,
              "short_id": [$sid]
            }
          }
       }]' "$CONFIG_FILE" > "$tmp_conf" 2>/dev/null

    if ! sbx_apply_config_safe "$tmp_conf"; then
        pause_for_enter
        return 1
    fi

    # 预检通过并应用成功后，持久化元数据
    local tmp_state
    tmp_state=$(mktemp /tmp/sbx_state_XXXXXX)
    jq --arg tag "$tag" \
       --arg name "$name" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg sni "$sni" \
       --arg pub "$pub_key" \
       --arg sid "$short_id" \
       '.nodes[$tag] = {
          "name": $name,
          "port": $port,
          "uuid": $uuid,
          "sni": $sni,
          "pub_key": $pub,
          "short_id": $sid,
          "created_at": (now | todate)
       }' "$STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
    rm -f "$tmp_state"

    printf '\n%b[5/5] 节点搭建成功！正在生成节点链接...%b\n\n' "$GREEN" "$NC"
    _show_node_by_tag "$tag"
    pause_for_enter
}

_show_node_by_tag() {
    local tag="$1"
    local node_data
    node_data=$(jq -r --arg t "$tag" '.nodes[$t] // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$node_data" ] || { printf '%b[!] 找不到该节点数据。%b\n' "$RED" "$NC"; return 1; }

    local name port uuid sni pub_key short_id ip_data ip
    name=$(echo "$node_data" | jq -r '.name')
    port=$(echo "$node_data" | jq -r '.port')
    uuid=$(echo "$node_data" | jq -r '.uuid')
    sni=$(echo "$node_data" | jq -r '.sni')
    pub_key=$(echo "$node_data" | jq -r '.pub_key')
    short_id=$(echo "$node_data" | jq -r '.short_id')

    ip_data=$(_get_public_ip)
    ip=$(echo "$ip_data" | cut -d'|' -f1)
    [ -n "$ip" ] || ip="您的服务器公网IP"

    local link
    link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&pbk=${pub_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision&fp=chrome#${name}"

    print_divider
    printf "  %b节点名称:%b  %s\n" "$CYAN" "$NC" "$name"
    printf "  %b协议类型:%b  VLESS-Reality + Vision\n" "$CYAN" "$NC"
    printf "  %b连接地址:%b  %s:%s\n" "$CYAN" "$NC" "$ip" "$port"
    printf "  %b用户 UUID:%b %s\n" "$CYAN" "$NC" "$uuid"
    printf "  %b伪装域名:%b  %s\n" "$CYAN" "$NC" "$sni"
    printf "  %bPublic Key:%b%s\n" "$CYAN" "$NC" "$pub_key"
    printf "  %bShort ID:%b  %s\n" "$CYAN" "$NC" "$short_id"
    print_divider
    printf "  %b分享链接 (直接复制导入客户端):%b\n" "$YELLOW$BOLD" "$NC"
    printf "  %s\n\n" "$link"

    if command -v qrencode >/dev/null 2>&1; then
        printf "  %b二维码:%b\n" "$CYAN" "$NC"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || true
    fi
}

list_reality_nodes() {
    init_sbx_config
    local count
    count=$(jq '.nodes | length' "$STATE_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        printf '\n  %b当前暂无已配置的 Reality 节点。%b\n' "$YELLOW" "$NC"
        return 1
    fi

    local tags=() i=1
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        tags+=("$t")
        local n p
        n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
        p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
        printf "  %b%d.%b %-20s  (端口: %s)\n" "$GREEN" "$i" "$NC" "$n" "$p"
        i=$((i + 1))
    done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
}

manage_reality() {
    while true; do
        menu_header "VLESS-Reality 节点管理"
        printf "  %b当前节点列表:%b\n" "$CYAN" "$NC"
        list_reality_nodes
        printf '\n'

        menu_single 1 "快速添加新的 VLESS-Reality 节点"
        menu_single 2 "查看指定节点链接与二维码"
        menu_single 3 "测试节点连通性 (本地端口检测)"
        menu_single 4 "删除节点"
        menu_single 0 "返回主菜单"

        _read_menu_choice rel_opt "> 请选择操作 [0-4]: "
        case "$rel_opt" in
            1) add_reality_node ;;
            2)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要查看的节点编号 [1-${#tags[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    printf '\n'
                    _show_node_by_tag "${tags[$((idx - 1))]}"
                    pause_for_enter
                fi
                ;;
            3)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n%b正在检测节点端口监听状态...%b\n' "$CYAN" "$NC"
                for t in "${tags[@]}"; do
                    local n p
                    n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
                    p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
                    if ss -tln | grep -wq ":$p"; then
                        printf "  [%s] 端口 %s -> %b正常监听中%b\n" "$n" "$p" "$GREEN" "$NC"
                    else
                        printf "  [%s] 端口 %s -> %b未在监听 / 核心未启动%b\n" "$n" "$p" "$RED" "$NC"
                    fi
                done
                pause_for_enter
                ;;
            4)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要删除的节点编号 [1-${#tags[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((idx - 1))]}"
                    local sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    if confirm_action "确认删除节点: ${sel_name}？"; then
                        acquire_lock || continue
                        # 从 config.json 移除候选并进行安全核心预检
                        local tmp_c tmp_s
                        tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c"
                        if ! sbx_apply_config_safe "$tmp_c"; then
                            pause_for_enter
                            continue
                        fi
                        # 预检通过并应用后，同步从 state.json 移除
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX)
                        jq --arg tag "$sel_tag" 'del(.nodes[$tag])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        rm -f "$tmp_s"
                        printf '%b[成功] 节点已删除！%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ==================== 端口转发与 WARP 出口分流 ====================

# ---------- TCP / UDP 端口转发 ----------
manage_forward() {
    while true; do
        menu_header "TCP / UDP 端口转发"
        init_sbx_config

        local fwd_rules=() i=1
        while IFS= read -r tag; do
            [ -n "$tag" ] || continue
            fwd_rules+=("$tag")
        done < <(jq -r '.inbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" 2>/dev/null)

        printf "  %b当前转发规则列表:%b\n" "$CYAN" "$NC"
        if [ ${#fwd_rules[@]} -eq 0 ]; then
            printf "    %b暂无端口转发规则%b\n\n" "$DIM" "$NC"
        else
            for tag in "${fwd_rules[@]}"; do
                local lp dest_ip dest_port
                lp=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE")
                dest_ip=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_address' "$CONFIG_FILE")
                dest_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_port' "$CONFIG_FILE")
                printf "  %b%d.%b 本机端口 %b%s%b -> 目标 %s:%s\n" "$GREEN" "$i" "$NC" "$YELLOW" "$lp" "$NC" "$dest_ip" "$dest_port"
                i=$((i + 1))
            done
            printf '\n'
        fi

        menu_single 1 "添加新的端口转发"
        menu_single 2 "删除端口转发规则"
        menu_single 0 "返回主菜单"

        _read_menu_choice fwd_opt "> 请选择操作 [0-2]: "
        case "$fwd_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service

                local local_port dest_host dest_port
                printf '\n'
                read -rp "  请输入本机监听端口: " local_port
                local_port="${local_port// /}"
                [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || {
                    printf '%b[!] 监听端口不合法。%b\n' "$RED" "$NC"; pause_for_enter; continue;
                }

                read -rp "  请输入目标 IP 或域名: " dest_host
                dest_host="${dest_host// /}"
                [ -n "$dest_host" ] || { printf '%b[!] 目标地址不能为空。%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                read -rp "  请输入目标端口: " dest_port
                dest_port="${dest_port// /}"
                [[ "$dest_port" =~ ^[0-9]+$ ]] && [ "$dest_port" -ge 1 ] && [ "$dest_port" -le 65535 ] || {
                    printf '%b[!] 目标端口不合法。%b\n' "$RED" "$NC"; pause_for_enter; continue;
                }

                local fwd_tag="fwd-${local_port}"
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_fwd_XXXXXX)
                jq --arg tag "$fwd_tag" \
                   --argjson lp "$local_port" \
                   --arg host "$dest_host" \
                   --argjson dp "$dest_port" \
                   '.inbounds = [.inbounds[] | select(.tag != $tag)] + [{
                      "type": "direct",
                      "tag": $tag,
                      "listen": "::",
                      "listen_port": $lp,
                      "override_address": $host,
                      "override_port": $dp
                   }]' "$CONFIG_FILE" > "$tmp_c"

                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi

                printf '\n%b[成功] 端口转发已添加: 本机 %s -> %s:%s%b\n' "$GREEN" "$local_port" "$dest_host" "$dest_port" "$NC"
                pause_for_enter
                ;;
            2)
                [ ${#fwd_rules[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要删除的转发规则编号 [1-${#fwd_rules[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#fwd_rules[@]}" ]; then
                    local sel_tag="${fwd_rules[$((idx - 1))]}"
                    if confirm_action "确认删除规则: ${sel_tag}？"; then
                        acquire_lock || continue
                        local tmp_c
                        tmp_c=$(mktemp /tmp/sbx_fwd_del_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c"
                        if ! sbx_apply_config_safe "$tmp_c"; then
                            pause_for_enter
                            continue
                        fi
                        printf '%b[成功] 规则已删除！%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ---------- Cloudflare WARP 出口与分流 ----------
_has_warp_outbound() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '((.endpoints[]? | select(.tag == "warp-out")) or (.outbounds[]? | select(.tag == "warp-out")))' "$CONFIG_FILE" >/dev/null 2>&1
}

manage_warp() {
    while true; do
        menu_header "Cloudflare WARP 出口与分流"
        init_sbx_config

        local warp_status
        if _has_warp_outbound; then
            warp_status="${GREEN}已配置开启${NC}"
        else
            warp_status="${DIM}未配置 / 已关闭${NC}"
        fi
        printf "  %b当前 WARP 状态:%b %b\n\n" "$CYAN" "$NC" "$warp_status"

        menu_single 1 "一键生成并接入 WARP WireGuard 出口"
        menu_single 2 "分流规则: 将 OpenAI (ChatGPT) 流量引导走 WARP"
        menu_single 3 "分流规则: 将主流流媒体 (Netflix/YouTube/Disney+) 引导走 WARP"
        menu_single 4 "彻底移除 WARP 出口与分流规则"
        menu_single 0 "返回主菜单"

        _read_menu_choice warp_opt "> 请选择操作 [0-4]: "
        case "$warp_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service

                printf '\n%b>>> 正在向 Cloudflare WARP 官方 API 注册设备与密钥...%b\n' "$CYAN" "$NC"
                local wg_keys priv_key pub_key
                wg_keys=$("$BIN_FILE" generate wg-keypair 2>/dev/null)
                priv_key=$(echo "$wg_keys" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
                pub_key=$(echo "$wg_keys" | awk '/PublicKey:/{print $2}' | tr -d '\r')

                if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
                    printf '%b[!] 生成 WireGuard 密钥对失败，请检查 sing-box 核心。%b\n' "$RED" "$NC"
                    pause_for_enter; continue;
                fi

                local install_id
                install_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || openssl rand -hex 16)
                local reg_payload reg_res
                reg_payload=$(jq -n --arg key "$pub_key" --arg iid "$install_id" \
                  '{key: $key, install_id: $iid, fcm_token: "", tos: (now | todateiso8601), model: "Linux", serial_number: $iid, locale: "en_US"}')

                reg_res=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
                  -H "User-Agent: okhttp/3.12.1" \
                  -H "CF-Client-Version: a-6.3-2158" \
                  -H "Content-Type: application/json" \
                  -d "$reg_payload" --connect-timeout 10 2>/dev/null)

                local v4_addr v6_addr peer_pub peer_ip
                v4_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v4 // empty')
                v6_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v6 // empty')
                peer_pub=$(echo "$reg_res" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
                peer_ip="162.159.192.8"

                [ -n "$v4_addr" ] || v4_addr="172.16.0.2"

                local addr_arr
                if [ -n "$v6_addr" ]; then
                    addr_arr="[\"${v4_addr}/32\", \"${v6_addr}/128\"]"
                else
                    addr_arr="[\"${v4_addr}/32\"]"
                fi

                local warp_endpoint
                warp_endpoint=$(jq -n \
                  --arg priv "$priv_key" \
                  --arg pub "$peer_pub" \
                  --arg pip "$peer_ip" \
                  --argjson addrs "$addr_arr" \
                  '{
                    "type": "wireguard",
                    "tag": "warp-out",
                    "address": $addrs,
                    "private_key": $priv,
                    "peers": [
                      {
                        "address": $pip,
                        "port": 2408,
                        "public_key": $pub,
                        "allowed_ips": ["0.0.0.0/0", "::/0"]
                      }
                    ]
                  }')

                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_warp_XXXXXX)
                jq --argjson ep "$warp_endpoint" '
                  .endpoints = ([.endpoints[]? | select(.tag != "warp-out")] + [$ep]) |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"

                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi

                printf '\n%b[成功] Cloudflare WARP 官方设备注册成功，WireGuard 端点已接入！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            2)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.domain_suffix? // []) != ["openai.com", "chatgpt.com", "ai.com"])] + [{
                      "action": "route",
                      "domain_suffix": ["openai.com", "chatgpt.com", "ai.com", "oaistatic.com", "oaiusercontent.com"],
                      "outbound": "warp-out"
                   }]' "$CONFIG_FILE" > "$tmp_c"
                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi
                printf '\n%b[成功] OpenAI / ChatGPT 域名分流规则已生效！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            3)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.domain_suffix? // []) != ["netflix.com", "disneyplus.com"])] + [{
                      "action": "route",
                      "domain_suffix": ["netflix.com", "nflxvideo.net", "disneyplus.com", "bamgrid.com"],
                      "outbound": "warp-out"
                   }]' "$CONFIG_FILE" > "$tmp_c"
                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi
                printf '\n%b[成功] 流媒体域名分流规则已生效！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            4)
                if confirm_action "彻底移除 WARP 出口与全部 WARP 关联分流规则？"; then
                    acquire_lock || continue
                    local tmp_c
                    tmp_c=$(mktemp /tmp/sbx_warp_del_XXXXXX)
                    jq '.endpoints = [.endpoints[]? | select(.tag != "warp-out")] |
                        .outbounds = [.outbounds[]? | select(.tag != "warp-out")] |
                        .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]' "$CONFIG_FILE" > "$tmp_c"
                    if ! sbx_apply_config_safe "$tmp_c"; then
                        pause_for_enter
                        continue
                    fi
                    printf '\n%b[成功] WARP 配置已彻底清除！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ==================== 彻底卸载与残留清理 ====================

uninstall_all() {
    menu_header "彻底卸载 SBX 及所有配置残留"
    printf '%b[警告] 此操作将彻底清除由 SBX 脚本部署的所有资源与配置：%b\n\n' "$RED$BOLD" "$NC"
    printf "  1. 停止并删除服务单元 (%s)\n" "$SERVICE_SYSTEMD"
    printf "  2. 永久删除配置目录 (%s，含所有节点/密钥/备份)\n" "$SBX_ROOT"
    printf "  3. 删除 TCP 网络调优文件 (%s) 并还原内核参数\n" "$TCP_SYSCTL_CONF"
    printf "  4. 删除日志文件 (%s)\n" "$LOG_FILE"
    printf "  5. 删除快捷指令 (%s)\n" "$SHORTCUT_PATH"
    printf "  6. 清除所有运行锁与临时缓存\n\n"
    printf '  %b安全说明: 不会触碰系统中既有的其他服务或历史脚本文件。%b\n\n' "$CYAN" "$NC"

    if ! confirm_action "确认彻底卸载 SBX 并删除全部配置与残留？" "n"; then
        printf '\n%b操作已取消。%b\n' "$YELLOW" "$NC"
        pause_for_enter
        return 0
    fi

    printf '\n%b>>> 正在停止服务并清理残留...%b\n' "$CYAN" "$NC"

    # 1. 停止与注销服务
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl stop sbx.service >/dev/null 2>&1 || true
        systemctl disable sbx.service >/dev/null 2>&1 || true
        rm -f "$SERVICE_SYSTEMD"
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-service sbx stop >/dev/null 2>&1 || true
        rc-update del sbx default >/dev/null 2>&1 || true
        rm -f "$SERVICE_OPENRC"
    fi

    # 2. 还原 sysctl 调优
    if [ -f "$TCP_SYSCTL_CONF" ]; then
        rm -f "$TCP_SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1 || true
        printf '  - 内核参数已恢复默认\n'
    fi

    # 3. 删除配置目录与日志
    rm -rf "$SBX_ROOT"
    rm -f "$LOG_FILE"
    rm -f "$LOCK_FILE"
    rm -f /tmp/sbx_* 2>/dev/null || true
    printf '  - 配置目录与日志缓存已清除\n'

    # 4. 删除快捷指令
    rm -f "$SHORTCUT_PATH"
    printf '  - 快捷指令已移除\n'

    printf '\n%b[成功] SBX 已完全卸载，所有配置与残留已彻底清理！%b\n\n' "$GREEN$BOLD" "$NC"
    exit 0
}

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
