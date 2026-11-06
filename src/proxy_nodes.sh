# ==================== VLESS-Reality 节点管理 ====================

_find_available_port() {
    local p="${1:-443}"
    while true; do
        if ! ss -tlnu 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | grep -wq "$p"; then
            echo "$p"
            return 0
        fi
        p=$((p + 1))
        [ "$p" -le 65535 ] || break
    done
    echo "4433"
}

_generate_reality_keys() {
    local out
    out=$("$BIN_FILE" generate reality-keypair 2>/dev/null)
    local priv pub
    priv=$(echo "$out" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
    pub=$(echo "$out" | awk '/PublicKey:/{print $2}' | tr -d '\r')
    printf '%s|%s' "$priv" "$pub"
}

add_reality_node() {
    menu_header "搭建 / 添加 VLESS-Reality 节点"
    acquire_lock || return 1
    install_singbox_bin || return 1
    init_sbx_config
    deploy_sbx_service

    printf '  %b[1/5] 设置节点端口%b\n' "$CYAN" "$NC"
    local rec_port port
    rec_port=$(_find_available_port 443)
    read -rp "  请输入监听端口 [默认 ${rec_port}]: " port
    port="${port// /}"
    port="${port:-$rec_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        printf '%b[!] 端口号不合法。%b\n' "$RED" "$NC"; pause_for_enter; return 1;
    }

    printf '\n  %b[2/5] 设置伪装域名 (SNI)%b\n' "$CYAN" "$NC"
    printf '  常用推荐: 1) addons.mozilla.org  2) gateway.icloud.com  3) www.microsoft.com\n'
    local sni sni_opt
    read -rp "  请选择或输入 SNI [直接回车默认 addons.mozilla.org]: " sni_opt
    sni_opt="${sni_opt// /}"
    case "$sni_opt" in
        1) sni="addons.mozilla.org" ;;
        2) sni="gateway.icloud.com" ;;
        3) sni="www.microsoft.com" ;;
        "") sni="addons.mozilla.org" ;;
        *) sni="$sni_opt" ;;
    esac

    printf '\n  %b[3/5] 生成安全密钥与认证凭据...%b\n' "$CYAN" "$NC"
    local uuid keys priv_key pub_key short_id tag
    uuid=$("$BIN_FILE" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
    keys=$(_generate_reality_keys)
    priv_key=$(echo "$keys" | cut -d'|' -f1)
    pub_key=$(echo "$keys" | cut -d'|' -f2)
    short_id=$(openssl rand -hex 8 2>/dev/null || echo "1a2b3c4d5e6f7a8b")
    tag="vless-reality-${port}"

    printf '\n  %b[4/5] 设置节点备注名称%b\n' "$CYAN" "$NC"
    local name
    read -rp "  请输入节点备注名称 [默认 Reality-${port}]: " name
    name="${name// /}"
    name="${name:-Reality-${port}}"

    # 写入配置
    sbx_backup_config
    local tmp_conf
    tmp_conf=$(mktemp /tmp/sbx_conf_XXXXXX)
    jq --arg tag "$tag" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg sni "$sni" \
       --arg priv "$priv_key" \
       --arg sid "$short_id" \
       '.inbounds = [.inbounds[] | select(.tag != $tag)] + [{
          "type": "vless",
          "tag": $tag,
          "listen": "::",
          "listen_port": $port,
          "sniff": true,
          "sniff_override_destination": true,
          "users": [{
            "uuid": $uuid,
            "flow": "xtls-rprx-vision"
          }],
          "tls": {
            "enabled": true,
            "server_name": $sni,
            "reality": {
              "enabled": true,
              "handshake": {
                "server": $sni,
                "server_port": 443
              },
              "private_key": $priv,
              "short_id": [$sid]
            }
          }
       }]' "$CONFIG_FILE" > "$tmp_conf" 2>/dev/null

    if [ -s "$tmp_conf" ] && jq -e . "$tmp_conf" >/dev/null 2>&1; then
        mv "$tmp_conf" "$CONFIG_FILE"
    else
        rm -f "$tmp_conf"
        printf '%b[错误] 生成配置文件异常。%b\n' "$RED" "$NC"
        pause_for_enter; return 1;
    fi

    # 保存元数据
    local tmp_state
    tmp_state=$(mktemp /tmp/sbx_state_XXXXXX)
    jq --arg tag "$tag" \
       --arg name "$name" \
       --argjson port "$port" \
       --arg uuid "$uuid" \
       --arg sni "$sni" \
       --arg pub "$pub_key" \
       --arg sid "$short_id" \
       '.nodes[$tag] = {
          "name": $name,
          "port": $port,
          "uuid": $uuid,
          "sni": $sni,
          "pub_key": $pub,
          "short_id": $sid,
          "created_at": (now | todate)
       }' "$STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
    rm -f "$tmp_state"

    # 重启并生效
    sbx_svc_action restart >/dev/null 2>&1 || true

    printf '\n%b[5/5] 节点搭建成功！正在生成节点链接...%b\n\n' "$GREEN" "$NC"
    _show_node_by_tag "$tag"
    pause_for_enter
}

_show_node_by_tag() {
    local tag="$1"
    local node_data
    node_data=$(jq -r --arg t "$tag" '.nodes[$t] // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$node_data" ] || { printf '%b[!] 找不到该节点数据。%b\n' "$RED" "$NC"; return 1; }

    local name port uuid sni pub_key short_id ip_data ip
    name=$(echo "$node_data" | jq -r '.name')
    port=$(echo "$node_data" | jq -r '.port')
    uuid=$(echo "$node_data" | jq -r '.uuid')
    sni=$(echo "$node_data" | jq -r '.sni')
    pub_key=$(echo "$node_data" | jq -r '.pub_key')
    short_id=$(echo "$node_data" | jq -r '.short_id')

    ip_data=$(_get_public_ip)
    ip=$(echo "$ip_data" | cut -d'|' -f1)
    [ -n "$ip" ] || ip="您的服务器公网IP"

    local link
    link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&pbk=${pub_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision&fp=chrome#${name}"

    print_divider
    printf "  %b节点名称:%b  %s\n" "$CYAN" "$NC" "$name"
    printf "  %b协议类型:%b  VLESS-Reality + Vision\n" "$CYAN" "$NC"
    printf "  %b连接地址:%b  %s:%s\n" "$CYAN" "$NC" "$ip" "$port"
    printf "  %b用户 UUID:%b %s\n" "$CYAN" "$NC" "$uuid"
    printf "  %b伪装域名:%b  %s\n" "$CYAN" "$NC" "$sni"
    printf "  %bPublic Key:%b%s\n" "$CYAN" "$NC" "$pub_key"
    printf "  %bShort ID:%b  %s\n" "$CYAN" "$NC" "$short_id"
    print_divider
    printf "  %b分享链接 (直接复制导入客户端):%b\n" "$YELLOW$BOLD" "$NC"
    printf "  %s\n\n" "$link"

    if command -v qrencode >/dev/null 2>&1; then
        printf "  %b二维码:%b\n" "$CYAN" "$NC"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || true
    fi
}

list_reality_nodes() {
    init_sbx_config
    local count
    count=$(jq '.nodes | length' "$STATE_FILE" 2>/dev/null || echo 0)
    if [ "$count" -eq 0 ]; then
        printf '\n  %b当前暂无已配置的 Reality 节点。%b\n' "$YELLOW" "$NC"
        return 1
    fi

    local tags=() i=1
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        tags+=("$t")
        local n p
        n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
        p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
        printf "  %b%d.%b %-20s  (端口: %s)\n" "$GREEN" "$i" "$NC" "$n" "$p"
        i=$((i + 1))
    done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
}

manage_reality() {
    while true; do
        menu_header "VLESS-Reality 节点管理"
        printf "  %b当前节点列表:%b\n" "$CYAN" "$NC"
        list_reality_nodes
        printf '\n'

        menu_single 1 "快速添加新的 VLESS-Reality 节点"
        menu_single 2 "查看指定节点链接与二维码"
        menu_single 3 "测试节点连通性 (本地端口检测)"
        menu_single 4 "删除节点"
        menu_single 0 "返回主菜单"

        _read_menu_choice rel_opt "> 请选择操作 [0-4]: "
        case "$rel_opt" in
            1) add_reality_node ;;
            2)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要查看的节点编号 [1-${#tags[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    printf '\n'
                    _show_node_by_tag "${tags[$((idx - 1))]}"
                    pause_for_enter
                fi
                ;;
            3)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n%b正在检测节点端口监听状态...%b\n' "$CYAN" "$NC"
                for t in "${tags[@]}"; do
                    local n p
                    n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
                    p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
                    if ss -tln | grep -wq ":$p"; then
                        printf "  [%s] 端口 %s -> %b正常监听中%b\n" "$n" "$p" "$GREEN" "$NC"
                    else
                        printf "  [%s] 端口 %s -> %b未在监听 / 核心未启动%b\n" "$n" "$p" "$RED" "$NC"
                    fi
                done
                pause_for_enter
                ;;
            4)
                local tags=() t
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要删除的节点编号 [1-${#tags[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((idx - 1))]}"
                    local sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    if confirm_action "确认删除节点: ${sel_name}？"; then
                        acquire_lock || continue
                        sbx_backup_config
                        # 从 config.json 移除
                        local tmp_c tmp_s
                        tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c" && mv "$tmp_c" "$CONFIG_FILE"
                        rm -f "$tmp_c"
                        # 从 state.json 移除
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX)
                        jq --arg tag "$sel_tag" 'del(.nodes[$tag])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        rm -f "$tmp_s"
                        sbx_svc_action restart >/dev/null 2>&1 || true
                        printf '%b[成功] 节点已删除！%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}
