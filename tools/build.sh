#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo '用法: bash tools/build.sh 输出路径' >&2
    exit 2
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$1
stage=$(mktemp "${out}.XXXXXX")
trap 'rm -f -- "$stage"' EXIT
for part in header system network proxy_core proxy_nodes proxy_features uninstall menus; do
    cat -- "$root/src/$part.sh"
    printf '\n'
done > "$stage"
bash -n "$stage"
chmod 755 "$stage"
mv -fT -- "$stage" "$out"
