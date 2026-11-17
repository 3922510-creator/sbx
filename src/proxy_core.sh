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
