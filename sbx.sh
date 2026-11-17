#!/usr/bin/env bash
# =====================================================================
# 项目名称: SBX (Sing-box & Linux VPS 工具箱)
# 版本: v5.1.0
# 快捷指令: sbx
# =====================================================================
set -o pipefail
SBX_VERSION="v5.1.0"

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
    [ "$w" -gt 0 ] || w=$(stty size 2>/dev/null | awk '{print $2}') || w=''
    case "$w" in ''|*[!0-9]*) w=60 ;; esac
    [ "$w" -ge 46 ] || w=46
    [ "$w" -le 68 ] || w=68
    printf '%s' "$w"
}

print_divider() {
    local w line="" i=0
    w=$(get_term_width)
    while [ "$i" -lt "$w" ]; do line="${line}─"; i=$((i + 1)); done
    printf '%b%s%b\n' "${DIM}${CYAN}" "$line" "$NC"
}

print_center() {
    local text="$1" color="${2:-$NC}" clean_text w pad_left
    clean_text=$(printf '%b' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    w=$(get_term_width)
    pad_left=$(( (w - ${#clean_text}) / 2 ))
    [ "$pad_left" -gt 0 ] || pad_left=0
    printf '%*s%b%s%b\n' "$pad_left" '' "$color" "$text" "$NC"
}

pause_for_enter() {
    printf '\n'
    read -rp "  回车继续..." _ || return 0
}

confirm_action() {
    local prompt="$1" default="${2:-n}" answer
    printf '\n%b%s%b\n' "$YELLOW" "$prompt" "$NC"
    read -rp "确认执行？回复 y / n [默认 ${default}]: " answer || return 1
    answer="${answer:-$default}"
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

menu_pair() {
    local num1="$1" txt1="$2" num2="$3" txt2="$4" col_w=27
    local left_str right_str clean_left pad
    left_str=$(printf "  %b%2s.%b %s" "$GREEN" "$num1" "$NC" "$txt1")
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
    printf "  %b%2s.%b %s\n" "$GREEN" "$1" "$NC" "$2"
}

menu_header() {
    clear_screen
    print_divider
    print_center "$1" "$PURPLE$BOLD"
    print_divider
}

_read_menu_choice() {
    local var_name="${1:-OPTION}" prompt="${2:-> 选择: }"
    printf '\n%b%s%b' "$CYAN" "$prompt" "$NC"
    read -r REPLY || REPLY=0
    REPLY="${REPLY// /}"
    eval "$var_name=\"\$REPLY\""
}

acquire_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    [ "${SBX_LOCKED:-0}" = 1 ] && return 0
    exec 210>"$LOCK_FILE" || return 1
    flock -n 210 || {
        printf '%b[!] 另一个 sbx 实例正在运行%b\n' "$RED" "$NC" >&2
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
    confirm_action "下载并运行 ${url}？" "y" || return 0
    local tmp
    tmp=$(mktemp /tmp/sbx_ext_XXXXXX) || return 1
    if curl -fsSL --connect-timeout 10 --max-time 60 "$url" -o "$tmp" 2>/dev/null || wget -qO "$tmp" "$url" 2>/dev/null; then
        grep -Eq '^#!/|(^|[[:space:]])(bash|sh)[[:space:]]' "$tmp" && bash "$tmp" || printf '%b[!] 脚本校验失败%b\n' "$RED" "$NC"
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

# ==================== Sing-box 核心与服务控制 ====================

ensure_dirs() {
    mkdir -p "$SBX_ROOT" "$META_DIR" "$BACKUP_DIR"
    chmod 700 "$SBX_ROOT" "$META_DIR" "$BACKUP_DIR"
}

sbx_service_status() {
    if [ ! -f "$SERVICE_SYSTEMD" ] && [ ! -f "$SERVICE_OPENRC" ]; then
        printf '%b未部署%b' "$DIM" "$NC"; return 0
    fi
    if [ "$INIT_SYS" = "systemd" ]; then
        systemctl is-active --quiet sbx.service 2>/dev/null && printf '%b运行中%b' "$GREEN" "$NC" || printf '%b已停止%b' "$RED" "$NC"
    elif [ "$INIT_SYS" = "openrc" ]; then
        rc-service sbx status 2>/dev/null | grep -q 'started' && printf '%b运行中%b' "$GREEN" "$NC" || printf '%b已停止%b' "$RED" "$NC"
    else
        printf '%b未知%b' "$YELLOW" "$NC"
    fi
}

install_singbox_bin() {
    [ -x "$BIN_FILE" ] && return 0
    printf '%b>>> 安装 Sing-box 核心...%b\n' "$CYAN" "$NC"
    local arch uname_m
    uname_m=$(uname -m)
    case "$uname_m" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        *) printf '%b[!] 不支持的架构: %s%b\n' "$RED" "$uname_m" "$NC"; return 1 ;;
    esac

    local tag url tmp_dir ver
    tag=$(curl -sL --connect-timeout 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null | grep '"tag_name":' | head -1 | cut -d'"' -f4)
    [ -n "$tag" ] || tag="v1.11.4"
    ver="${tag#v}"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${arch}.tar.gz"
    tmp_dir=$(mktemp -d /tmp/sbx_core_XXXXXX)
    if curl -fsSL --connect-timeout 10 -o "${tmp_dir}/sb.tar.gz" "$url"; then
        tar -xzf "${tmp_dir}/sb.tar.gz" -C "$tmp_dir"
        local found_bin
        found_bin=$(find "$tmp_dir" -type f -name "sing-box" | head -1)
        if [ -n "$found_bin" ]; then
            install -m 755 "$found_bin" "$BIN_FILE"
            rm -rf "$tmp_dir"
            printf '%b[OK] Sing-box 已就绪: %s%b\n' "$GREEN" "$("$BIN_FILE" version | head -1)" "$NC"
            return 0
        fi
    fi
    rm -rf "$tmp_dir"
    printf '%b[!] 下载或安装 Sing-box 失败%b\n' "$RED" "$NC"
    return 1
}

deploy_sbx_service() {
    if [ "$INIT_SYS" = "systemd" ]; then
        cat > "$SERVICE_SYSTEMD" <<EOF
[Unit]
Description=Sing-box Service (SBX)
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
depend() { need net; after firewall; }
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
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [{ "action": "sniff" }],
    "final": "direct"
  }
}
EOF
    fi
    [ -f "$STATE_FILE" ] || echo '{"format": 5, "nodes": {}}' > "$STATE_FILE"
}

sbx_backup_config() {
    ensure_dirs
    [ -f "$CONFIG_FILE" ] || return 0
    cp -pf "$CONFIG_FILE" "${BACKUP_DIR}/config_$(date +'%Y%m%d_%H%M%S').json" 2>/dev/null || true
    local old_baks
    old_baks=$(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null | tail -n +11)
    [ -n "$old_baks" ] && rm -f $old_baks 2>/dev/null || true
}

sbx_check_config() {
    [ -x "$BIN_FILE" ] || return 0
    "$BIN_FILE" check -c "$CONFIG_FILE" >/dev/null 2>&1
}

sbx_apply_config_safe() {
    local candidate="$1"
    if [ ! -s "$candidate" ]; then
        printf '%b[!] 待写入配置为空%b\n' "$RED" "$NC"
        rm -f "$candidate"
        return 1
    fi
    local check_err
    if ! check_err=$("$BIN_FILE" check -c "$candidate" 2>&1); then
        printf '\n%b[核心预检失败] 配置未通过 Sing-box 校验，原配置未改动:%b\n%b%s%b\n' "$RED$BOLD" "$NC" "$YELLOW" "$check_err" "$NC"
        rm -f "$candidate"
        return 1
    fi
    sbx_backup_config
    mv -f "$candidate" "$CONFIG_FILE"
    sbx_svc_action restart >/dev/null 2>&1 || true
    sleep 0.5
    if [ "$INIT_SYS" = "systemd" ] && ! systemctl is-active --quiet sbx.service 2>/dev/null; then
        local latest_bak
        latest_bak=$(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null | head -1)
        if [ -n "$latest_bak" ]; then
            printf '\n%b[!] 服务启动异常，已自动回滚至上一版本%b\n' "$RED" "$NC"
            cp -pf "$latest_bak" "$CONFIG_FILE"
            sbx_svc_action restart >/dev/null 2>&1 || true
        fi
        return 1
    fi
    return 0
}

sbx_svc_action() {
    local act="$1"
    [ "$INIT_SYS" = "systemd" ] && systemctl "$act" sbx.service
    [ "$INIT_SYS" = "openrc" ] && rc-service sbx "$act"
}

manage_service() {
    while true; do
        menu_header "Sing-box 核心与服务"
        local ver
        ver=$([ -x "$BIN_FILE" ] && "$BIN_FILE" version 2>/dev/null | head -1 | awk '{print $3}' || echo "未安装")
        printf "  %b状态:%b %b  |  %b核心:%b %s\n" "$CYAN" "$NC" "$(sbx_service_status)" "$CYAN" "$NC" "$ver"
        printf "  %b配置:%b %s\n\n" "$CYAN" "$NC" "$CONFIG_FILE"

        menu_pair 1 "启动服务" 2 "停止服务"
        menu_pair 3 "重启服务" 4 "查看日志"
        menu_pair 5 "校验配置" 6 "回滚备份"
        menu_single 7 "更新 / 重装核心"
        menu_single 0 "返回"

        _read_menu_choice svc_opt "> 选择 [0-7]: "
        case "$svc_opt" in
            1) sbx_svc_action start; pause_for_enter ;;
            2) sbx_svc_action stop; pause_for_enter ;;
            3) sbx_svc_action restart; pause_for_enter ;;
            4)
                printf '\n'
                [ "$INIT_SYS" = "systemd" ] && journalctl -u sbx.service -n 30 --no-pager || tail -n 30 "$LOG_FILE" 2>/dev/null
                pause_for_enter ;;
            5)
                printf '\n'
                "$BIN_FILE" check -c "$CONFIG_FILE" && printf '%b[OK] 配置校验通过%b\n' "$GREEN" "$NC" || printf '%b[!] 配置存在错误%b\n' "$RED" "$NC"
                pause_for_enter ;;
            6)
                local choice i=1 b_list=() f
                while IFS= read -r f; do [ -n "$f" ] && b_list+=("$f"); done < <(ls -1t "${BACKUP_DIR}"/config_*.json 2>/dev/null)
                [ ${#b_list[@]} -gt 0 ] || { printf '\n%b[!] 暂无备份%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                printf '\n'
                for f in "${b_list[@]}"; do printf "  %b%d.%b %s\n" "$GREEN" "$i" "$NC" "$(basename "$f")"; i=$((i + 1)); done
                read -rp "  选择备份编号: " choice; choice="${choice// /}"
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#b_list[@]}" ]; then
                    local target="${b_list[$((choice - 1))]}"
                    if confirm_action "恢复 $(basename "$target")？"; then
                        cp -pf "$target" "$CONFIG_FILE"
                        sbx_svc_action restart >/dev/null 2>&1 || true
                        printf '%b[OK] 已恢复并重启%b\n' "$GREEN" "$NC"; pause_for_enter
                    fi
                fi ;;
            7) rm -f "$BIN_FILE"; install_singbox_bin; pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}

# ==================== VLESS-Reality 节点管理 ====================

_find_available_port() {
    local p="${1:-443}"
    while [ "$p" -le 65535 ]; do
        ss -tlnu 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | grep -wq "$p" || { echo "$p"; return 0; }
        p=$((p + 1))
    done
    echo "4433"
}

_generate_reality_keys() {
    local out priv pub
    out=$("$BIN_FILE" generate reality-keypair 2>/dev/null)
    priv=$(echo "$out" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
    pub=$(echo "$out" | awk '/PublicKey:/{print $2}' | tr -d '\r')
    printf '%s|%s' "$priv" "$pub"
}

_is_node_warp() {
    local tag="$1"
    [ -f "$STATE_FILE" ] || return 1
    jq -e --arg t "$tag" '(.warp_nodes // []) | index($t) != null' "$STATE_FILE" >/dev/null 2>&1
}

add_reality_node() {
    menu_header "添加 VLESS-Reality 节点"
    acquire_lock || return 1
    install_singbox_bin || return 1
    init_sbx_config
    deploy_sbx_service

    local rec_port port sni sni_opt name
    rec_port=$(_find_available_port 443)
    read -rp "  1. 监听端口 [默认 ${rec_port}]: " port
    port="${port// /}"; port="${port:-$rec_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; return 1;
    }

    printf '  2. 伪装域名: 1) addons.mozilla.org  2) gateway.icloud.com  3) www.microsoft.com\n'
    read -rp "     选择或输入 SNI [默认 1]: " sni_opt
    sni_opt="${sni_opt// /}"
    case "$sni_opt" in
        1|"") sni="addons.mozilla.org" ;;
        2)    sni="gateway.icloud.com" ;;
        3)    sni="www.microsoft.com" ;;
        *)    sni="$sni_opt" ;;
    esac

    read -rp "  3. 节点备注 [默认 Reality-${port}]: " name
    name="${name// /}"; name="${name:-Reality-${port}}"

    local uuid keys priv_key pub_key short_id tag tmp_conf tmp_state
    uuid=$("$BIN_FILE" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
    keys=$(_generate_reality_keys)
    priv_key=$(echo "$keys" | cut -d'|' -f1)
    pub_key=$(echo "$keys" | cut -d'|' -f2)
    short_id=$(openssl rand -hex 8 2>/dev/null || echo "1a2b3c4d5e6f7a8b")
    tag="vless-reality-${port}"

    tmp_conf=$(mktemp /tmp/sbx_conf_XXXXXX)
    jq --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv_key" --arg sid "$short_id" '
      .inbounds = [.inbounds[] | select(.tag != $tag)] + [{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": $port,
        "tcp_fast_open": true,
        "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
        "tls": {
          "enabled": true,
          "server_name": $sni,
          "reality": {
            "enabled": true,
            "handshake": { "server": $sni, "server_port": 443 },
            "private_key": $priv,
            "short_id": [$sid]
          }
        }
      }]' "$CONFIG_FILE" > "$tmp_conf" 2>/dev/null

    sbx_apply_config_safe "$tmp_conf" || { pause_for_enter; return 1; }

    tmp_state=$(mktemp /tmp/sbx_state_XXXXXX)
    jq --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg pub "$pub_key" --arg sid "$short_id" '
      .nodes[$tag] = {
        "name": $name, "port": $port, "uuid": $uuid, "sni": $sni,
        "pub_key": $pub, "short_id": $sid, "created_at": (now | todate)
      }' "$STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
    rm -f "$tmp_state"

    printf '\n%b[OK] 节点创建成功%b\n' "$GREEN" "$NC"
    _show_node_by_tag "$tag"
    pause_for_enter
}

_show_node_by_tag() {
    local tag="$1" node_data
    node_data=$(jq -r --arg t "$tag" '.nodes[$t] // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$node_data" ] || { printf '%b[!] 节点不存在%b\n' "$RED" "$NC"; return 1; }

    local name port uuid sni pub_key short_id ip link route_mode
    name=$(echo "$node_data" | jq -r '.name')
    port=$(echo "$node_data" | jq -r '.port')
    uuid=$(echo "$node_data" | jq -r '.uuid')
    sni=$(echo "$node_data" | jq -r '.sni')
    pub_key=$(echo "$node_data" | jq -r '.pub_key')
    short_id=$(echo "$node_data" | jq -r '.short_id')
    ip=$(_get_public_ip | cut -d'|' -f1)
    [ -n "$ip" ] || ip="服务器IP"
    _is_node_warp "$tag" && route_mode="${YELLOW}指定走 WARP${NC}" || route_mode="${CYAN}默认分流/直连${NC}"

    link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&pbk=${pub_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision&fp=chrome#${name}"

    print_divider
    printf "  %b名称:%b %s  |  %b端口:%b %s  |  %b出站:%b %b\n" "$CYAN" "$NC" "$name" "$CYAN" "$NC" "$port" "$CYAN" "$NC" "$route_mode"
    printf "  %b地址:%b %s  |  %bSNI :%b %s\n" "$CYAN" "$NC" "$ip" "$CYAN" "$NC" "$sni"
    printf "  %bUUID:%b %s\n" "$CYAN" "$NC" "$uuid"
    printf "  %bPBK :%b %s  |  %bSID:%b %s\n" "$CYAN" "$NC" "$pub_key" "$CYAN" "$NC" "$short_id"
    print_divider
    printf "  %b分享链接:%b\n  %s\n" "$YELLOW$BOLD" "$NC" "$link"
    if command -v qrencode >/dev/null 2>&1; then
        printf "\n"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || true
    fi
}

list_reality_nodes() {
    init_sbx_config
    local count
    count=$(jq '.nodes | length' "$STATE_FILE" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] || { printf '  %b暂无节点%b\n' "$DIM" "$NC"; return 1; }

    local i=1 t n p w_badge
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
        p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
        _is_node_warp "$t" && w_badge=" ${YELLOW}[WARP]${NC}" || w_badge=""
        printf "  %b%d.%b %-18s (端口: %s)%b\n" "$GREEN" "$i" "$NC" "$n" "$p" "$w_badge"
        i=$((i + 1))
    done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
}

manage_reality() {
    while true; do
        menu_header "VLESS-Reality 节点管理"
        list_reality_nodes || true
        printf '\n'
        menu_pair 1 "添加节点" 2 "查看链接/二维码"
        menu_pair 3 "检测端口状态" 4 "删除节点"
        menu_single 0 "返回"

        _read_menu_choice rel_opt "> 选择 [0-4]: "
        case "$rel_opt" in
            1) add_reality_node ;;
            2)
                local tags=() t idx
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                read -rp "  节点编号 [1-${#tags[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    _show_node_by_tag "${tags[$((idx - 1))]}"
                    pause_for_enter
                fi ;;
            3)
                local tags=() t n p
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                for t in "${tags[@]}"; do
                    n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
                    p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
                    ss -tln | grep -wq ":$p" && printf "  [%s] :%s -> %b监听中%b\n" "$n" "$p" "$GREEN" "$NC" || printf "  [%s] :%s -> %b未监听%b\n" "$n" "$p" "$RED" "$NC"
                done
                pause_for_enter ;;
            4)
                local tags=() t idx
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                read -rp "  删除节点编号 [1-${#tags[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((idx - 1))]}" sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    if confirm_action "删除节点 ${sel_name}？"; then
                        acquire_lock || continue
                        local tmp_s tmp_c1 tmp_c2
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX)
                        jq --arg tag "$sel_tag" 'del(.nodes[$tag]) | .warp_nodes = ([.warp_nodes[]? | select(. != $tag)])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        tmp_c1=$(mktemp /tmp/sbx_c1_XXXXXX)
                        tmp_c2=$(mktemp /tmp/sbx_c2_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c1"
                        if type _sync_warp_node_rules >/dev/null 2>&1; then
                            _sync_warp_node_rules "$tmp_c1" "$tmp_c2"
                            rm -f "$tmp_c1"
                        else
                            mv "$tmp_c1" "$tmp_c2"
                        fi
                        sbx_apply_config_safe "$tmp_c2" && printf '%b[OK] 节点已删除%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi ;;
            0) return 0 ;;
        esac
    done
}

# ==================== 端口转发与 WARP 出口分流 ====================

# ---------- TCP / UDP 端口转发 ----------
manage_forward() {
    while true; do
        menu_header "TCP / UDP 端口转发"
        init_sbx_config
        local fwd_rules=() i=1 tag lp dest_ip dest_port
        while IFS= read -r tag; do [ -n "$tag" ] && fwd_rules+=("$tag"); done < <(jq -r '.inbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" 2>/dev/null)

        if [ ${#fwd_rules[@]} -eq 0 ]; then
            printf "  %b暂无转发规则%b\n\n" "$DIM" "$NC"
        else
            for tag in "${fwd_rules[@]}"; do
                lp=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE")
                dest_ip=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_address' "$CONFIG_FILE")
                dest_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_port' "$CONFIG_FILE")
                printf "  %b%d.%b 本机 :%b%s%b -> %s:%s\n" "$GREEN" "$i" "$NC" "$YELLOW" "$lp" "$NC" "$dest_ip" "$dest_port"
                i=$((i + 1))
            done
            printf '\n'
        fi

        menu_pair 1 "添加转发" 2 "删除转发"
        menu_single 0 "返回"
        _read_menu_choice fwd_opt "> 选择 [0-2]: "
        case "$fwd_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service
                local local_port dest_host dest_port tmp_c
                read -rp "  本机监听端口: " local_port; local_port="${local_port// /}"
                [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || { printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                read -rp "  目标地址 (IP/域名): " dest_host; dest_host="${dest_host// /}"
                [ -n "$dest_host" ] || { printf '%b[!] 地址不能为空%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                read -rp "  目标端口: " dest_port; dest_port="${dest_port// /}"
                [[ "$dest_port" =~ ^[0-9]+$ ]] && [ "$dest_port" -ge 1 ] && [ "$dest_port" -le 65535 ] || { printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                tmp_c=$(mktemp /tmp/sbx_fwd_XXXXXX)
                jq --arg tag "fwd-${local_port}" --argjson lp "$local_port" --arg host "$dest_host" --argjson dp "$dest_port" '
                  .inbounds = [.inbounds[] | select(.tag != $tag)] + [{
                    "type": "direct", "tag": $tag, "listen": "::",
                    "listen_port": $lp, "override_address": $host, "override_port": $dp
                  }]' "$CONFIG_FILE" > "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已添加 :%s -> %s:%s%b\n' "$GREEN" "$local_port" "$dest_host" "$dest_port" "$NC"
                pause_for_enter ;;
            2)
                [ ${#fwd_rules[@]} -gt 0 ] || { pause_for_enter; continue; }
                local idx
                read -rp "  删除规则编号 [1-${#fwd_rules[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#fwd_rules[@]}" ]; then
                    local sel_tag="${fwd_rules[$((idx - 1))]}" tmp_c
                    confirm_action "删除规则 ${sel_tag}？" || continue
                    acquire_lock || continue
                    tmp_c=$(mktemp /tmp/sbx_fwd_del_XXXXXX)
                    jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已删除%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi ;;
            0) return 0 ;;
        esac
    done
}

# ---------- Cloudflare WARP 出口与分流 ----------
_has_warp_outbound() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '((.endpoints[]? | select(.tag == "warp-out")) or (.outbounds[]? | select(.tag == "warp-out")))' "$CONFIG_FILE" >/dev/null 2>&1
}

_is_warp_global() {
    [ -f "$CONFIG_FILE" ] || return 1
    [ "$(jq -r '.route.final // empty' "$CONFIG_FILE" 2>/dev/null)" = "warp-out" ]
}

_has_warp_ai_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-ai" or ((.rule_set? // []) | index("geosite-ai"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_has_warp_stream_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-stream" or ((.rule_set? // []) | index("geosite-stream"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_get_warp_custom_domains() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.warp_custom_domains[]? // empty' "$STATE_FILE" 2>/dev/null
}

_get_warp_nodes() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.warp_nodes[]? // empty' "$STATE_FILE" 2>/dev/null
}

_sync_warp_custom_rules() {
    local cfg_in="$1" cfg_out="$2" doms_json
    doms_json=$(jq -c '.warp_custom_domains // []' "$STATE_FILE" 2>/dev/null || echo "[]")
    if [ "$doms_json" = "[]" ] || [ -z "$doms_json" ]; then
        jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .rule_set != null or .inbound != null)]' "$cfg_in" > "$cfg_out"
    else
        jq --argjson doms "$doms_json" '
          .route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .rule_set != null or .inbound != null)] + [{
            "action": "route", "domain_suffix": $doms, "outbound": "warp-out"
          }]
        ' "$cfg_in" > "$cfg_out"
    fi
}

_sync_warp_node_rules() {
    local cfg_in="$1" cfg_out="$2" nodes_json
    nodes_json=$(jq -c '[.warp_nodes[]? as $t | select(.nodes[$t] != null) | $t]' "$STATE_FILE" 2>/dev/null || echo "[]")
    if [ "$nodes_json" = "[]" ] || [ -z "$nodes_json" ]; then
        jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .inbound == null)]' "$cfg_in" > "$cfg_out"
    else
        jq --argjson ibs "$nodes_json" '
          .route.rules = (
            (if ([.route.rules[]? | select(.ip_is_private == true)] | length) == 0 then
              [{ "action": "route", "ip_is_private": true, "outbound": "direct" }]
            else [] end) +
            [.route.rules[]? | select(.outbound != "warp-out" or .inbound == null)] +
            [{ "action": "route", "inbound": $ibs, "outbound": "warp-out" }]
          )
        ' "$cfg_in" > "$cfg_out"
    fi
}

_manage_warp_nodes() {
    if ! _has_warp_outbound; then
        printf '\n%b[!] 请先选 1 接入 WARP 出口%b\n' "$YELLOW" "$NC"
        pause_for_enter; return 1
    fi
    while true; do
        menu_header "指定节点走 WARP"
        local tags=() t i=1 n p st
        while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
        if [ "${#tags[@]}" -eq 0 ]; then
            printf "  %b当前暂无 Reality 节点，请先在节点管理中添加。%b\n" "$YELLOW" "$NC"
            pause_for_enter; return 0
        fi
        printf "  %b选择节点编号以 开启 / 关闭 该节点全流量走 WARP:%b\n\n" "$DIM" "$NC"
        for t in "${tags[@]}"; do
            n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
            p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
            if _is_node_warp "$t"; then
                st="${GREEN}[已绑定 WARP]${NC}"
            else
                st="${DIM}[默认分流/直连]${NC}"
            fi
            printf "  %b%2d.%b %-18s (:%s)  %b\n" "$GREEN" "$i" "$NC" "$n" "$p" "$st"
            i=$((i + 1))
        done
        print_divider
        printf "  %b输入节点序号切换状态  |  a 全部开启  |  c 全部取消  |  0 返回%b\n" "$DIM" "$NC"
        _read_menu_choice wn_opt "> 选择: "
        local tmp_s tmp_c
        case "$wn_opt" in
            0|'') return 0 ;;
            a|A)
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                jq '.warp_nodes = (.nodes | keys)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 所有节点已绑定走 WARP%b\n' "$GREEN" "$NC"
                sleep 0.6 ;;
            c|C)
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                jq '.warp_nodes = []' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已取消所有节点的 WARP 绑定%b\n' "$GREEN" "$NC"
                sleep 0.6 ;;
            *)
                if [[ "$wn_opt" =~ ^[0-9]+$ ]] && [ "$wn_opt" -ge 1 ] && [ "$wn_opt" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((wn_opt - 1))]}" sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    acquire_lock || continue
                    tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                    if _is_node_warp "$sel_tag"; then
                        jq --arg t "$sel_tag" '.warp_nodes = ([.warp_nodes[]? | select(. != $t)])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 节点 [%s] 已恢复默认出站%b\n' "$GREEN" "$sel_name" "$NC"
                    else
                        jq --arg t "$sel_tag" '.warp_nodes = (((.warp_nodes // []) + [$t]) | unique)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 节点 [%s] 已指定走 WARP%b\n' "$GREEN" "$sel_name" "$NC"
                    fi
                    sleep 0.6
                fi ;;
        esac
    done
}

_show_warp_rules_detail() {
    menu_header "WARP 分流规则详情"
    local ep_st mode_st ai_st stream_st c_doms=() w_nodes=() d t n
    _has_warp_outbound && ep_st="${GREEN}已开启 (WireGuard)${NC}" || ep_st="${DIM}未配置${NC}"
    _is_warp_global && mode_st="${YELLOW}全局 WARP${NC}" || mode_st="${CYAN}按规则分流 (默认直连)${NC}"
    _has_warp_ai_rule && ai_st="${GREEN}已启用${NC} (geosite-category-ai-chat-!cn)" || ai_st="${DIM}未启用${NC}"
    _has_warp_stream_rule && stream_st="${GREEN}已启用${NC} (geosite-category-entertainment@!cn)" || stream_st="${DIM}未启用${NC}"
    while IFS= read -r d; do [ -n "$d" ] && c_doms+=("$d"); done < <(_get_warp_custom_domains)
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$(jq -r --arg t "$t" '.nodes[$t].name // empty' "$STATE_FILE")
        [ -n "$n" ] && w_nodes+=("${n}(${t#vless-reality-})")
    done < <(_get_warp_nodes)

    printf "  %b端点状态:%b %b  |  %b出站模式:%b %b\n" "$CYAN" "$NC" "$ep_st" "$CYAN" "$NC" "$mode_st"
    print_divider
    printf "  1. %b指定节点分流:%b %s\n" "$BOLD" "$NC" "${w_nodes[*]:-无}"
    printf "  2. %bAI 智能分流 :%b %b\n" "$BOLD" "$NC" "$ai_st"
    printf "  3. %b流媒体分流  :%b %b\n" "$BOLD" "$NC" "$stream_st"
    printf "  4. %b自定义域名  :%b %s\n" "$BOLD" "$NC" "${c_doms[*]:-无}"
    print_divider
    pause_for_enter
}

_test_warp_connectivity() {
    printf '\n%b>>> 测试 WARP 连通性...%b\n' "$CYAN" "$NC"
    _has_warp_outbound || { printf '%b[!] 请先接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; return 1; }
    local ep_json test_port=15891 tmp_test test_pid trace_res ip colo warp_flag
    ep_json=$(jq -c '.endpoints[]? | select(.tag == "warp-out")' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$ep_json" ] || { printf '%b[!] 未找到 warp-out 端点%b\n' "$RED" "$NC"; pause_for_enter; return 1; }

    tmp_test=$(mktemp /tmp/sbx_test_warp_XXXXXX.json)
    jq -n --argjson ep "$ep_json" --argjson port "$test_port" '{
      "log": { "level": "warn" }, "endpoints": [$ep],
      "inbounds": [{ "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $port }],
      "outbounds": [{ "type": "direct", "tag": "direct" }],
      "route": { "rules": [{ "outbound": "warp-out" }] }
    }' > "$tmp_test"

    "$BIN_FILE" run -c "$tmp_test" >/dev/null 2>&1 &
    test_pid=$!; sleep 1.6
    trace_res=$(curl -x "socks5h://127.0.0.1:${test_port}" -s --connect-timeout 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    kill "$test_pid" 2>/dev/null || true; rm -f "$tmp_test"

    [ -n "$trace_res" ] || { printf '%b[!] WARP 连接超时%b\n' "$RED" "$NC"; pause_for_enter; return 1; }
    ip=$(echo "$trace_res" | awk -F= '/^ip=/{print $2}')
    colo=$(echo "$trace_res" | awk -F= '/^colo=/{print $2}')
    warp_flag=$(echo "$trace_res" | awk -F= '/^warp=/{print $2}')
    printf "  %b状态:%b %b连通%b  |  %bIP:%b %s  |  %b节点:%b %s  |  %bWARP:%b %s\n" \
        "$CYAN" "$NC" "$GREEN" "$NC" "$CYAN" "$NC" "${ip:-未知}" "$CYAN" "$NC" "${colo:-未知}" "$CYAN" "$NC" "${warp_flag:-未知}"
    pause_for_enter
}

_toggle_geosite_rule() {
    local r_tag="$1" r_name="$2" r_file="$3"
    _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; return 1; }
    acquire_lock || return 1
    local tmp_c
    tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
    if jq -e --arg t "$r_tag" '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == $t or ((.rule_set? // []) | index($t))))' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq --arg t "$r_tag" '
          .route.rule_set = [.route.rule_set[]? | select(.tag != $t)] |
          .route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.rule_set != $t and ((.rule_set? // []) | index($t) == null)))]
        ' "$CONFIG_FILE" > "$tmp_c"
        sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] %s 已关闭%b\n' "$GREEN" "$r_name" "$NC"
    else
        jq --arg t "$r_tag" --arg url "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${r_file}" '
          .route.rule_set = ([.route.rule_set[]? | select(.tag != $t)] + [{
            "tag": $t, "type": "remote", "format": "binary", "url": $url, "download_detour": "direct"
          }]) |
          .route.rules = ([.route.rules[]? | select(.outbound != "warp-out" or (.rule_set != $t and ((.rule_set? // []) | index($t) == null)))] + [{
            "action": "route", "rule_set": $t, "outbound": "warp-out"
          }])
        ' "$CONFIG_FILE" > "$tmp_c"
        sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] %s 已开启%b\n' "$GREEN" "$r_name" "$NC"
    fi
    pause_for_enter
}

manage_warp() {
    while true; do
        menu_header "Cloudflare WARP 出口与分流"
        init_sbx_config
        local warp_st mode_st ai_tag stream_tag dom_cnt node_cnt
        _has_warp_outbound && warp_st="${GREEN}已开启${NC}" || warp_st="${DIM}未配置${NC}"
        _is_warp_global && mode_st="${YELLOW}全局 WARP${NC}" || mode_st="${CYAN}分流模式${NC}"
        _has_warp_ai_rule && ai_tag="${GREEN}开${NC}" || ai_tag="${DIM}关${NC}"
        _has_warp_stream_rule && stream_tag="${GREEN}开${NC}" || stream_tag="${DIM}关${NC}"
        dom_cnt=$(jq '.warp_custom_domains | length' "$STATE_FILE" 2>/dev/null || echo 0)
        node_cnt=$(jq '[.warp_nodes[]? as $t | select(.nodes[$t] != null)] | length' "$STATE_FILE" 2>/dev/null || echo 0)

        printf "  %bWARP:%b %b  |  %b模式:%b %b\n" "$CYAN" "$NC" "$warp_st" "$CYAN" "$NC" "$mode_st"
        printf "  %b分流:%b 节点[%b%s%b] · AI[%b] · 流媒体[%b] · 域名[%b%s%b]\n\n" \
            "$CYAN" "$NC" "$YELLOW" "$node_cnt" "$NC" "$ai_tag" "$stream_tag" "$CYAN" "$dom_cnt" "$NC"

        menu_pair 1 "接入/重置 WARP" 2 "查看规则详情"
        menu_pair 3 "测试 WARP 连通" 4 "全局 WARP 开关"
        print_divider
        menu_pair 5 "指定节点走 WARP" 6 "AI 分流开关"
        menu_pair 7 "流媒体分流开关" 8 "添加分流域名"
        menu_pair 9 "删除分流域名" 10 "彻底移除 WARP"
        menu_single 0 "返回"

        _read_menu_choice warp_opt "> 选择 [0-10]: "
        case "$warp_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service
                printf '\n%b>>> 注册 Cloudflare WARP...%b\n' "$CYAN" "$NC"
                local wg_keys priv_key pub_key install_id reg_payload reg_res v4_addr v6_addr peer_pub addr_arr warp_endpoint tmp_c
                wg_keys=$("$BIN_FILE" generate wg-keypair 2>/dev/null)
                priv_key=$(echo "$wg_keys" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
                pub_key=$(echo "$wg_keys" | awk '/PublicKey:/{print $2}' | tr -d '\r')
                [ -n "$priv_key" ] && [ -n "$pub_key" ] || { printf '%b[!] 生成密钥失败%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                install_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || openssl rand -hex 16)
                reg_payload=$(jq -n --arg key "$pub_key" --arg iid "$install_id" \
                  '{key: $key, install_id: $iid, fcm_token: "", tos: (now | todateiso8601), model: "Linux", serial_number: $iid, locale: "en_US"}')
                reg_res=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
                  -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.3-2158" -H "Content-Type: application/json" \
                  -d "$reg_payload" --connect-timeout 10 2>/dev/null)

                v4_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v4 // "172.16.0.2"')
                v6_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v6 // empty')
                peer_pub=$(echo "$reg_res" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
                [ -n "$v6_addr" ] && addr_arr="[\"${v4_addr}/32\", \"${v6_addr}/128\"]" || addr_arr="[\"${v4_addr}/32\"]"

                warp_endpoint=$(jq -n --arg priv "$priv_key" --arg pub "$peer_pub" --argjson addrs "$addr_arr" '{
                  "type": "wireguard", "tag": "warp-out", "address": $addrs, "private_key": $priv,
                  "peers": [{ "address": "162.159.192.8", "port": 2408, "public_key": $pub, "allowed_ips": ["0.0.0.0/0", "::/0"] }]
                }')
                tmp_c=$(mktemp /tmp/sbx_warp_XXXXXX)
                jq --argjson ep "$warp_endpoint" '
                  .endpoints = ([.endpoints[]? | select(.tag != "warp-out")] + [$ep]) |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] WARP 端点已就绪 (%s)%b\n' "$GREEN" "$v4_addr" "$NC"
                pause_for_enter ;;
            2) _show_warp_rules_detail ;;
            3) _test_warp_connectivity ;;
            4)
                _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                acquire_lock || continue
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_global_XXXXXX)
                if _is_warp_global; then
                    jq '.route.final = "direct"' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] 已切换为【分流模式 (默认直连)】%b\n' "$GREEN" "$NC"
                else
                    confirm_action "开启全局 WARP (所有出站默认走 WARP)？" || continue
                    jq '
                      .route.rules = (
                        (if ([.route.rules[]? | select(.ip_is_private == true)] | length) == 0 then
                          [{ "action": "route", "ip_is_private": true, "outbound": "direct" }]
                        else [] end) + .route.rules
                      ) | .route.final = "warp-out"
                    ' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] 已开启【全局 WARP 出口】%b\n' "$GREEN" "$NC"
                fi
                pause_for_enter ;;
            5) _manage_warp_nodes ;;
            6) _toggle_geosite_rule "geosite-ai" "AI 智能分流" "geosite-category-ai-chat-!cn.srs" ;;
            7) _toggle_geosite_rule "geosite-stream" "流媒体分流" "geosite-category-entertainment@!cn.srs" ;;
            8)
                _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                local raw_doms new_doms=() d tmp_s tmp_c json_arr
                read -rp "  输入分流域名 (空格分隔, 如 claude.ai reddit.com): " raw_doms
                raw_doms=$(echo "$raw_doms" | tr -d '\r')
                [ -n "$raw_doms" ] || continue
                for d in $raw_doms; do
                    d=$(echo "$d" | tr '[:upper:]' '[:lower:]' | sed -E 's|^https?://||; s|/.*$||')
                    [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && new_doms+=("$d")
                done
                [ "${#new_doms[@]}" -gt 0 ] || { printf '%b[!] 域名格式无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_state_XXXXXX); tmp_c=$(mktemp /tmp/sbx_cfg_XXXXXX)
                json_arr=$(printf '%s\n' "${new_doms[@]}" | jq -R . | jq -s .)
                jq --argjson new "$json_arr" '.warp_custom_domains = ((.warp_custom_domains // []) + $new | unique)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已添加: %s%b\n' "$GREEN" "${new_doms[*]}" "$NC"
                pause_for_enter ;;
            9)
                local cur_doms=() d idx=1 del_choice tmp_s tmp_c
                while IFS= read -r d; do [ -n "$d" ] && cur_doms+=("$d"); done < <(_get_warp_custom_domains)
                [ "${#cur_doms[@]}" -gt 0 ] || { printf '\n%b[!] 暂无自定义域名%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                printf '\n'
                for d in "${cur_doms[@]}"; do printf "  %b%2d.%b %s\n" "$CYAN" "$idx" "$NC" "$d"; idx=$((idx + 1)); done
                read -rp "  输入编号删除 (a 清空全部, 0 返回): " del_choice; del_choice="${del_choice// /}"
                case "$del_choice" in
                    0|'') continue ;;
                    a|A)
                        confirm_action "清空所有自定义分流域名？" || continue
                        acquire_lock || continue
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                        jq '.warp_custom_domains = []' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已清空%b\n' "$GREEN" "$NC"
                        pause_for_enter ;;
                    *)
                        if [[ "$del_choice" =~ ^[0-9]+$ ]] && [ "$del_choice" -ge 1 ] && [ "$del_choice" -le "${#cur_doms[@]}" ]; then
                            local target_dom="${cur_doms[$((del_choice - 1))]}"
                            acquire_lock || continue
                            tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                            jq --arg d "$target_dom" '.warp_custom_domains = [.warp_custom_domains[]? | select(. != $d)]' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                            _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                            sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已删除: %s%b\n' "$GREEN" "$target_dom" "$NC"
                            pause_for_enter
                        fi ;;
                esac ;;
            10)
                confirm_action "彻底移除 WARP 出口及全部关联规则？" || continue
                acquire_lock || continue
                local tmp_c tmp_s
                tmp_c=$(mktemp /tmp/sbx_warp_del_XXXXXX); tmp_s=$(mktemp /tmp/sbx_state_del_XXXXXX)
                jq '
                  .endpoints = [.endpoints[]? | select(.tag != "warp-out")] |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")] |
                  .route.final = "direct" |
                  .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-ai" and .tag != "geosite-stream")] |
                  .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"
                jq '.warp_custom_domains = [] | .warp_nodes = []' "$STATE_FILE" > "$tmp_s" 2>/dev/null && mv "$tmp_s" "$STATE_FILE"
                sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] WARP 及分流规则已移除%b\n' "$GREEN" "$NC"
                pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}

# ==================== 彻底卸载与残留清理 ====================

uninstall_all() {
    menu_header "彻底卸载 SBX"
    printf '  %b将停止并移除以下资源:%b\n' "$RED$BOLD" "$NC"
    printf "  - 服务单元 (%s)\n  - 配置与备份 (%s)\n  - TCP 调优 (%s)\n  - 快捷指令 (%s)\n\n" \
        "$SERVICE_SYSTEMD" "$SBX_ROOT" "$TCP_SYSCTL_CONF" "$SHORTCUT_PATH"

    confirm_action "确认彻底卸载 SBX 并删除全部配置？" "n" || return 0

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

    if [ -f "$TCP_SYSCTL_CONF" ]; then
        rm -f "$TCP_SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1 || true
    fi
    rm -rf "$SBX_ROOT"
    rm -f "$LOG_FILE" "$LOCK_FILE" /tmp/sbx_* 2>/dev/null || true
    rm -f "$SHORTCUT_PATH"

    printf '\n%b[OK] SBX 已完全卸载%b\n\n' "$GREEN$BOLD" "$NC"
    exit 0
}

# ==================== 主菜单与交互界面 ====================

menu_logo() {
    clear_screen
    print_divider
    printf "  %bSBX %s%b · Sing-box & Linux VPS 工具箱 (%bsbx%b)\n" "$PURPLE$BOLD" "$SBX_VERSION" "$NC" "$GREEN" "$NC"
    print_divider

    local os_brief cores load mem_pct sbx_stat
    os_brief=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 | awk '{print $1" "$2}')
    [ -n "$os_brief" ] || os_brief="Linux"
    cores=$(nproc 2>/dev/null || echo "1")
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")
    mem_pct=$(free 2>/dev/null | awk 'NR==2{printf "%.0f%%", $3*100/$2}')
    sbx_stat=$(sbx_service_status)

    printf "  %b系统:%b %s (%s核) | %b负载:%b %s | %b内存:%b %s | %b服务:%b %b\n" \
        "$CYAN" "$NC" "$os_brief" "$cores" \
        "$CYAN" "$NC" "$load" \
        "$CYAN" "$NC" "$mem_pct" \
        "$CYAN" "$NC" "$sbx_stat"
    print_divider
}

show_main_menu() {
    menu_logo

    printf '  %b[ 系统维护 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 1 "系统状态总览" 2 "系统更新与组件"
    menu_pair 3 "系统垃圾清理" 4 "修改 Root 密码"
    menu_single 5 "主机名与时区"

    printf '\n  %b[ 网络优化与安全 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 6 "Swap 虚拟内存" 7 "DNS 优化设置"
    menu_pair 8 "TCP 调优与 BBR" 9 "BestTrace 回程"
    menu_pair 10 "流媒体解锁检测" 11 "UFW 防火墙管理"

    printf '\n  %b[ Sing-box 代理 ]%b\n' "$CYAN$BOLD" "$NC"
    menu_pair 12 "VLESS-Reality 节点" 13 "TCP/UDP 端口转发"
    menu_pair 14 "WARP 出口与分流" 15 "核心与服务维护"

    print_divider
    menu_pair 16 "彻底卸载 SBX" 0 "退出脚本"

    _read_menu_choice MAIN_OPT "> 选择 [0-16]: "
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
        0) printf '\n%b感谢使用，再见！%b\n' "$GREEN" "$NC"; exit 0 ;;
        *) printf '\n%b[!] 请输入 0-16%b\n' "$RED" "$NC"; sleep 0.6 ;;
    esac
}

main() {
    set +x
    umask 077
    [ "$EUID" -eq 0 ] || {
        printf '%b[!] 请以 root 身份运行%b\n' "$RED" "$NC" >&2
        exit 1
    }
    platform_detect
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
