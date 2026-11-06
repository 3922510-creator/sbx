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
