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
    local mode="${1:-install}"
    if [ "$mode" != update ] && [ -x "$BIN_FILE" ]; then return 0; fi
    printf '%b>>> 安装 Sing-box 核心...%b\n' "$CYAN" "$NC"
    local arch uname_m
    uname_m=$(uname -m)
    case "$uname_m" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        *) printf '%b[!] 不支持的架构: %s%b\n' "$RED" "$uname_m" "$NC"; return 1 ;;
    esac

    local tag url tmp_dir ver member version rc=1
    tag=$(curl -fsSL --connect-timeout 5 --max-time 15 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er .tag_name)
    if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%b[!] 无法获取核心版本，未替换现有核心%b\n' "$RED" "$NC"
        return 1
    fi
    ver="${tag#v}"
    member="sing-box-${ver}-linux-${arch}/sing-box"
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${member%/*}.tar.gz"
    tmp_dir=$(mktemp -d "${BIN_FILE}.XXXXXX") || return 1
    if curl -fsSL --connect-timeout 10 --max-time 180 -o "$tmp_dir/sb.tar.gz" "$url" &&
       tar -xOzf "$tmp_dir/sb.tar.gz" "$member" > "$tmp_dir/sing-box" &&
       chmod 755 "$tmp_dir/sing-box" && version=$("$tmp_dir/sing-box" version) &&
       { [ ! -f "$CONFIG_FILE" ] || "$tmp_dir/sing-box" check -c "$CONFIG_FILE"; } &&
       mv -f "$tmp_dir/sing-box" "$BIN_FILE"; then
        printf '%b[OK] %s%b\n' "$GREEN" "${version%%$'\n'*}" "$NC"
        rc=0
    else
        printf '%b[!] 下载、校验或安装失败，未替换现有核心%b\n' "$RED" "$NC"
    fi
    rm -rf "$tmp_dir"
    return "$rc"
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
    local backup
    backup=$(mktemp "$BACKUP_DIR/config_$(date +'%Y%m%d_%H%M%S')_XXXXXX.json") || return 1
    if ! cp -p "$CONFIG_FILE" "$backup" ||
       { [ -f "$STATE_FILE" ] && ! cp -p "$STATE_FILE" "${backup%.json}.state"; }; then
        rm -f "$backup" "${backup%.json}.state"
        return 1
    fi
    printf '%s\n' "$backup"
}

_sbx_prune_backups() {
    local old
    while IFS= read -r old; do
        rm -f "$old" "${old%.json}.state"
    done < <(ls -1t "$BACKUP_DIR"/config_*.json 2>/dev/null | tail -n +11)
}

sbx_check_config() {
    [ -x "$BIN_FILE" ] || return 0
    "$BIN_FILE" check -c "$CONFIG_FILE" >/dev/null 2>&1
}

sbx_apply_config_safe() {
    local candidate="$1" state="${2:-}" backup check_err
    if [ ! -s "$candidate" ] || { [ -n "$state" ] && ! jq -e 'type == "object"' "$state" >/dev/null; }; then
        printf '%b[!] 待写入的配置或状态无效%b\n' "$RED" "$NC"
    elif ! check_err=$("$BIN_FILE" check -c "$candidate" 2>&1); then
        printf '\n%b[核心预检失败] 原配置未改动:%b\n%s\n' "$RED$BOLD" "$NC" "$check_err"
    elif ! backup=$(sbx_backup_config); then
        printf '%b[!] 无法备份，原配置未改动%b\n' "$RED" "$NC"
    elif mv -f "$candidate" "$CONFIG_FILE" && _sbx_restart_checked &&
         { [ -z "$state" ] || mv -f "$state" "$STATE_FILE"; }; then
        _sbx_prune_backups
        return 0
    elif cp -pf "$backup" "$CONFIG_FILE" && _sbx_restart_checked; then
        printf '\n%b[!] 应用失败，已恢复上一版配置并重启%b\n' "$RED" "$NC"
    else
        printf '\n%b[!] 应用失败且未能验证旧服务恢复，请检查日志。备份: %s%b\n' "$RED" "$backup" "$NC"
    fi
    rm -f "$candidate"
    [ -z "$state" ] || rm -f "$state"
    return 1
}

_sbx_restart_checked() {
    sbx_svc_action restart || return 1
    sleep 0.5
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet sbx.service ;;
        openrc) rc-service sbx status ;;
        *) return 1 ;;
    esac
}

sbx_svc_action() {
    case "$INIT_SYS" in
        systemd) systemctl "$1" sbx.service ;;
        openrc) rc-service sbx "$1" ;;
        *) return 1 ;;
    esac
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
                        acquire_lock || continue
                        local candidate state=""
                        candidate=$(mktemp "${CONFIG_FILE}.XXXXXX") || continue
                        if [ -f "${target%.json}.state" ]; then
                            state=$(mktemp "${STATE_FILE}.XXXXXX") && cp "${target%.json}.state" "$state" || {
                                rm -f "$candidate" "$state"; continue;
                            }
                        elif ! confirm_action "旧备份没有面板状态，仅恢复核心配置可能导致显示不一致，继续？"; then
                            rm -f "$candidate"; continue
                        fi
                        if cp "$target" "$candidate" && sbx_apply_config_safe "$candidate" "$state"; then
                            printf '%b[OK] 已恢复并重启%b\n' "$GREEN" "$NC"
                        fi
                        rm -f "$candidate" "$state"
                        pause_for_enter
                    fi
                fi ;;
            7) acquire_lock && install_singbox_bin update; pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}
