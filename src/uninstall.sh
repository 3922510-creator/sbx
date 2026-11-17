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
