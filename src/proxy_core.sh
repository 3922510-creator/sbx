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
    "rules": []
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
