#!/usr/bin/env bash
set -euo pipefail

mode=${1:-install}
if [[ $# -gt 1 || ( "$mode" != install && "$mode" != --run ) ]]; then
    echo '用法: bash install.sh [--run]' >&2
    exit 2
fi
if (( EUID != 0 )); then
    echo '[!] 请以 root 用户权限运行。' >&2
    exit 1
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
tmp_dir=$(mktemp -d)
stage=''
trap 'rm -rf -- "$tmp_dir"; if [[ -n "$stage" ]]; then rm -f -- "$stage"; fi' EXIT

# 拉取同一份源码快照，避免逐个文件下载时跨越两次提交。
if [[ ! -f "$source_dir/tools/build.sh" ]]; then
    curl -qfsSL --connect-timeout 8 --max-time 60 \
        https://codeload.github.com/3922510-creator/sbx/tar.gz/refs/heads/main \
        -o "$tmp_dir/source.tar.gz"
    mkdir "$tmp_dir/source"
    tar -xzf "$tmp_dir/source.tar.gz" --strip-components=1 -C "$tmp_dir/source"
    source_dir="$tmp_dir/source"
fi
bash "$source_dir/tools/build.sh" "$tmp_dir/sbx"

if [[ "$mode" == --run ]]; then
    bash "$tmp_dir/sbx"
else
    mkdir -p /usr/local/bin
    stage=$(mktemp /usr/local/bin/.sbx.XXXXXX)
    install -m 755 "$tmp_dir/sbx" "$stage"
    mv -fT -- "$stage" /usr/local/bin/sbx
    stage=''
    echo '[成功] 已安装到 /usr/local/bin/sbx，输入 sbx 打开面板。'
fi
