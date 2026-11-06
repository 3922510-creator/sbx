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
