# ==================== VLESS-Reality 节点管理 ====================

_find_available_port() {
    local p="${1:-443}"
    while [ "$p" -le 65535 ]; do
        ss -tlnu 2>/dev/null | awk '{print $5}' | awk -F: '{print $NF}' | grep -wq "$p" || { echo "$p"; return 0; }
        p=$((p + 1))
    done
    echo "4433"
}

_generate_reality_keys() {
    local out priv pub
    out=$("$BIN_FILE" generate reality-keypair 2>/dev/null)
    priv=$(echo "$out" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
    pub=$(echo "$out" | awk '/PublicKey:/{print $2}' | tr -d '\r')
    printf '%s|%s' "$priv" "$pub"
}

_is_node_warp() {
    local tag="$1"
    [ -f "$STATE_FILE" ] || return 1
    jq -e --arg t "$tag" '(.warp_nodes // []) | index($t) != null' "$STATE_FILE" >/dev/null 2>&1
}

add_reality_node() {
    menu_header "添加 VLESS-Reality 节点"
    acquire_lock || return 1
    install_singbox_bin || return 1
    init_sbx_config
    deploy_sbx_service

    local rec_port port sni sni_opt name
    rec_port=$(_find_available_port 443)
    read -rp "  1. 监听端口 [默认 ${rec_port}]: " port
    port="${port// /}"; port="${port:-$rec_port}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; return 1;
    }

    printf '  2. 伪装域名: 1) addons.mozilla.org  2) gateway.icloud.com  3) www.microsoft.com\n'
    read -rp "     选择或输入 SNI [默认 1]: " sni_opt
    sni_opt="${sni_opt// /}"
    case "$sni_opt" in
        1|"") sni="addons.mozilla.org" ;;
        2)    sni="gateway.icloud.com" ;;
        3)    sni="www.microsoft.com" ;;
        *)    sni="$sni_opt" ;;
    esac

    read -rp "  3. 节点备注 [默认 Reality-${port}]: " name
    name="${name// /}"; name="${name:-Reality-${port}}"

    local uuid keys priv_key pub_key short_id tag tmp_conf tmp_state
    uuid=$("$BIN_FILE" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
    keys=$(_generate_reality_keys)
    priv_key=$(echo "$keys" | cut -d'|' -f1)
    pub_key=$(echo "$keys" | cut -d'|' -f2)
    short_id=$(openssl rand -hex 8 2>/dev/null || echo "1a2b3c4d5e6f7a8b")
    tag="vless-reality-${port}"

    tmp_conf=$(mktemp /tmp/sbx_conf_XXXXXX)
    jq --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg priv "$priv_key" --arg sid "$short_id" '
      .inbounds = [.inbounds[] | select(.tag != $tag)] + [{
        "type": "vless",
        "tag": $tag,
        "listen": "::",
        "listen_port": $port,
        "tcp_fast_open": true,
        "users": [{ "uuid": $uuid, "flow": "xtls-rprx-vision" }],
        "tls": {
          "enabled": true,
          "server_name": $sni,
          "reality": {
            "enabled": true,
            "handshake": { "server": $sni, "server_port": 443 },
            "private_key": $priv,
            "short_id": [$sid]
          }
        }
      }]' "$CONFIG_FILE" > "$tmp_conf" 2>/dev/null

    sbx_apply_config_safe "$tmp_conf" || { pause_for_enter; return 1; }

    tmp_state=$(mktemp /tmp/sbx_state_XXXXXX)
    jq --arg tag "$tag" --arg name "$name" --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg pub "$pub_key" --arg sid "$short_id" '
      .nodes[$tag] = {
        "name": $name, "port": $port, "uuid": $uuid, "sni": $sni,
        "pub_key": $pub, "short_id": $sid, "created_at": (now | todate)
      }' "$STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
    rm -f "$tmp_state"

    printf '\n%b[OK] 节点创建成功%b\n' "$GREEN" "$NC"
    _show_node_by_tag "$tag"
    pause_for_enter
}

_show_node_by_tag() {
    local tag="$1" node_data
    node_data=$(jq -r --arg t "$tag" '.nodes[$t] // empty' "$STATE_FILE" 2>/dev/null)
    [ -n "$node_data" ] || { printf '%b[!] 节点不存在%b\n' "$RED" "$NC"; return 1; }

    local name port uuid sni pub_key short_id ip link route_mode
    name=$(echo "$node_data" | jq -r '.name')
    port=$(echo "$node_data" | jq -r '.port')
    uuid=$(echo "$node_data" | jq -r '.uuid')
    sni=$(echo "$node_data" | jq -r '.sni')
    pub_key=$(echo "$node_data" | jq -r '.pub_key')
    short_id=$(echo "$node_data" | jq -r '.short_id')
    ip=$(_get_public_ip | cut -d'|' -f1)
    [ -n "$ip" ] || ip="服务器IP"
    _is_node_warp "$tag" && route_mode="${YELLOW}指定走 WARP${NC}" || route_mode="${CYAN}默认分流/直连${NC}"

    link="vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&pbk=${pub_key}&sid=${short_id}&type=tcp&flow=xtls-rprx-vision&fp=chrome#${name}"

    print_divider
    printf "  %b名称:%b %s  |  %b端口:%b %s  |  %b出站:%b %b\n" "$CYAN" "$NC" "$name" "$CYAN" "$NC" "$port" "$CYAN" "$NC" "$route_mode"
    printf "  %b地址:%b %s  |  %bSNI :%b %s\n" "$CYAN" "$NC" "$ip" "$CYAN" "$NC" "$sni"
    printf "  %bUUID:%b %s\n" "$CYAN" "$NC" "$uuid"
    printf "  %bPBK :%b %s  |  %bSID:%b %s\n" "$CYAN" "$NC" "$pub_key" "$CYAN" "$NC" "$short_id"
    print_divider
    printf "  %b分享链接:%b\n  %s\n" "$YELLOW$BOLD" "$NC" "$link"
    if command -v qrencode >/dev/null 2>&1; then
        printf "\n"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || true
    fi
}

list_reality_nodes() {
    init_sbx_config
    local count
    count=$(jq '.nodes | length' "$STATE_FILE" 2>/dev/null || echo 0)
    [ "$count" -gt 0 ] || { printf '  %b暂无节点%b\n' "$DIM" "$NC"; return 1; }

    local i=1 t n p w_badge
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
        p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
        _is_node_warp "$t" && w_badge=" ${YELLOW}[WARP]${NC}" || w_badge=""
        printf "  %b%d.%b %-18s (端口: %s)%b\n" "$GREEN" "$i" "$NC" "$n" "$p" "$w_badge"
        i=$((i + 1))
    done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
}

manage_reality() {
    while true; do
        menu_header "VLESS-Reality 节点管理"
        list_reality_nodes || true
        printf '\n'
        menu_pair 1 "添加节点" 2 "查看链接/二维码"
        menu_pair 3 "检测端口状态" 4 "删除节点"
        menu_single 0 "返回"

        _read_menu_choice rel_opt "> 选择 [0-4]: "
        case "$rel_opt" in
            1) add_reality_node ;;
            2)
                local tags=() t idx
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                read -rp "  节点编号 [1-${#tags[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    _show_node_by_tag "${tags[$((idx - 1))]}"
                    pause_for_enter
                fi ;;
            3)
                local tags=() t n p
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                for t in "${tags[@]}"; do
                    n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
                    p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
                    ss -tln | grep -wq ":$p" && printf "  [%s] :%s -> %b监听中%b\n" "$n" "$p" "$GREEN" "$NC" || printf "  [%s] :%s -> %b未监听%b\n" "$n" "$p" "$RED" "$NC"
                done
                pause_for_enter ;;
            4)
                local tags=() t idx
                while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
                [ ${#tags[@]} -gt 0 ] || { pause_for_enter; continue; }
                read -rp "  删除节点编号 [1-${#tags[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((idx - 1))]}" sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    if confirm_action "删除节点 ${sel_name}？"; then
                        acquire_lock || continue
                        local tmp_s tmp_c1 tmp_c2
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX)
                        jq --arg tag "$sel_tag" 'del(.nodes[$tag]) | .warp_nodes = ([.warp_nodes[]? | select(. != $tag)])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        tmp_c1=$(mktemp /tmp/sbx_c1_XXXXXX)
                        tmp_c2=$(mktemp /tmp/sbx_c2_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c1"
                        if type _sync_warp_node_rules >/dev/null 2>&1; then
                            _sync_warp_node_rules "$tmp_c1" "$tmp_c2"
                            rm -f "$tmp_c1"
                        else
                            mv "$tmp_c1" "$tmp_c2"
                        fi
                        sbx_apply_config_safe "$tmp_c2" && printf '%b[OK] 节点已删除%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi ;;
            0) return 0 ;;
        esac
    done
}
