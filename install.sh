#!/usr/bin/env bash
# =====================================================================
# SBX 面板一键安装脚本
# 项目地址: https://github.com/3922510-creator/sbx
# =====================================================================
set -euo pipefail

SBX_INSTALL_DIR="/usr/local/bin"
SBX_BIN="${SBX_INSTALL_DIR}/sbx"
REMOTE_RAW_URL="${SBX_RAW_URL:-https://raw.githubusercontent.com/3922510-creator/sbx/main/sbx.sh}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "[!] 请以 root 用户权限运行此安装器。" >&2
    exit 1
fi

mkdir -p "$SBX_INSTALL_DIR"

# 优先使用本地同目录的 sbx.sh，若没有则从 GitHub 下载
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "${SCRIPT_DIR}/sbx.sh" ]; then
    install -m 755 "${SCRIPT_DIR}/sbx.sh" "$SBX_BIN"
    echo "[成功] 已从本地文件安装 sbx 至 ${SBX_BIN}"
else
    echo ">>> 正在从 GitHub 获取最新版本..."
    tmp_file=$(mktemp /tmp/sbx_install_XXXXXX)
    if curl -fsSL --connect-timeout 8 --max-time 30 "$REMOTE_RAW_URL" -o "$tmp_file"; then
        install -m 755 "$tmp_file" "$SBX_BIN"
        rm -f "$tmp_file"
        echo "[成功] 已安装最新版 sbx 至 ${SBX_BIN}"
    else
        rm -f "$tmp_file"
        echo "[错误] 从远程下载 sbx 失败，请检查网络连接。" >&2
        exit 1
    fi
fi

echo "================================================="
echo " 安装成功！直接在终端输入 sbx 即可唤起管理面板。"
echo "================================================="
