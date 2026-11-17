# ==================== 端口转发与 WARP 出口分流 ====================

# ---------- TCP / UDP 端口转发 ----------
manage_forward() {
    while true; do
        menu_header "TCP / UDP 端口转发"
        init_sbx_config
        local fwd_rules=() i=1 tag lp dest_ip dest_port
        while IFS= read -r tag; do [ -n "$tag" ] && fwd_rules+=("$tag"); done < <(jq -r '.inbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" 2>/dev/null)

        if [ ${#fwd_rules[@]} -eq 0 ]; then
            printf "  %b暂无转发规则%b\n\n" "$DIM" "$NC"
        else
            for tag in "${fwd_rules[@]}"; do
                lp=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE")
                dest_ip=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_address' "$CONFIG_FILE")
                dest_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_port' "$CONFIG_FILE")
                printf "  %b%d.%b 本机 :%b%s%b -> %s:%s\n" "$GREEN" "$i" "$NC" "$YELLOW" "$lp" "$NC" "$dest_ip" "$dest_port"
                i=$((i + 1))
            done
            printf '\n'
        fi

        menu_pair 1 "添加转发" 2 "删除转发"
        menu_single 0 "返回"
        _read_menu_choice fwd_opt "> 选择 [0-2]: "
        case "$fwd_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service
                local local_port dest_host dest_port tmp_c
                read -rp "  本机监听端口: " local_port; local_port="${local_port// /}"
                [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || { printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                read -rp "  目标地址 (IP/域名): " dest_host; dest_host="${dest_host// /}"
                [ -n "$dest_host" ] || { printf '%b[!] 地址不能为空%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                read -rp "  目标端口: " dest_port; dest_port="${dest_port// /}"
                [[ "$dest_port" =~ ^[0-9]+$ ]] && [ "$dest_port" -ge 1 ] && [ "$dest_port" -le 65535 ] || { printf '%b[!] 端口无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                tmp_c=$(mktemp /tmp/sbx_fwd_XXXXXX)
                jq --arg tag "fwd-${local_port}" --argjson lp "$local_port" --arg host "$dest_host" --argjson dp "$dest_port" '
                  .inbounds = [.inbounds[] | select(.tag != $tag)] + [{
                    "type": "direct", "tag": $tag, "listen": "::",
                    "listen_port": $lp, "override_address": $host, "override_port": $dp
                  }]' "$CONFIG_FILE" > "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已添加 :%s -> %s:%s%b\n' "$GREEN" "$local_port" "$dest_host" "$dest_port" "$NC"
                pause_for_enter ;;
            2)
                [ ${#fwd_rules[@]} -gt 0 ] || { pause_for_enter; continue; }
                local idx
                read -rp "  删除规则编号 [1-${#fwd_rules[@]}]: " idx; idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#fwd_rules[@]}" ]; then
                    local sel_tag="${fwd_rules[$((idx - 1))]}" tmp_c
                    confirm_action "删除规则 ${sel_tag}？" || continue
                    acquire_lock || continue
                    tmp_c=$(mktemp /tmp/sbx_fwd_del_XXXXXX)
                    jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已删除%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi ;;
            0) return 0 ;;
        esac
    done
}

# ---------- Cloudflare WARP 出口与分流 ----------
_has_warp_outbound() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '((.endpoints[]? | select(.tag == "warp-out")) or (.outbounds[]? | select(.tag == "warp-out")))' "$CONFIG_FILE" >/dev/null 2>&1
}

_is_warp_global() {
    [ -f "$CONFIG_FILE" ] || return 1
    [ "$(jq -r '.route.final // empty' "$CONFIG_FILE" 2>/dev/null)" = "warp-out" ]
}

_has_warp_ai_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-ai" or ((.rule_set? // []) | index("geosite-ai"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_has_warp_stream_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-stream" or ((.rule_set? // []) | index("geosite-stream"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_get_warp_custom_domains() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.warp_custom_domains[]? // empty' "$STATE_FILE" 2>/dev/null
}

_get_warp_nodes() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.warp_nodes[]? // empty' "$STATE_FILE" 2>/dev/null
}

_sync_warp_custom_rules() {
    local cfg_in="$1" cfg_out="$2" doms_json
    doms_json=$(jq -c '.warp_custom_domains // []' "$STATE_FILE" 2>/dev/null || echo "[]")
    if [ "$doms_json" = "[]" ] || [ -z "$doms_json" ]; then
        jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .rule_set != null or .inbound != null)]' "$cfg_in" > "$cfg_out"
    else
        jq --argjson doms "$doms_json" '
          .route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .rule_set != null or .inbound != null)] + [{
            "action": "route", "domain_suffix": $doms, "outbound": "warp-out"
          }]
        ' "$cfg_in" > "$cfg_out"
    fi
}

_sync_warp_node_rules() {
    local cfg_in="$1" cfg_out="$2" nodes_json
    nodes_json=$(jq -c '[.warp_nodes[]? as $t | select(.nodes[$t] != null) | $t]' "$STATE_FILE" 2>/dev/null || echo "[]")
    if [ "$nodes_json" = "[]" ] || [ -z "$nodes_json" ]; then
        jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or .inbound == null)]' "$cfg_in" > "$cfg_out"
    else
        jq --argjson ibs "$nodes_json" '
          .route.rules = (
            (if ([.route.rules[]? | select(.ip_is_private == true)] | length) == 0 then
              [{ "action": "route", "ip_is_private": true, "outbound": "direct" }]
            else [] end) +
            [.route.rules[]? | select(.outbound != "warp-out" or .inbound == null)] +
            [{ "action": "route", "inbound": $ibs, "outbound": "warp-out" }]
          )
        ' "$cfg_in" > "$cfg_out"
    fi
}

_manage_warp_nodes() {
    if ! _has_warp_outbound; then
        printf '\n%b[!] 请先选 1 接入 WARP 出口%b\n' "$YELLOW" "$NC"
        pause_for_enter; return 1
    fi
    while true; do
        menu_header "指定节点走 WARP"
        local tags=() t i=1 n p st
        while IFS= read -r t; do [ -n "$t" ] && tags+=("$t"); done < <(jq -r '.nodes | keys[]' "$STATE_FILE" 2>/dev/null)
        if [ "${#tags[@]}" -eq 0 ]; then
            printf "  %b当前暂无 Reality 节点，请先在节点管理中添加。%b\n" "$YELLOW" "$NC"
            pause_for_enter; return 0
        fi
        printf "  %b选择节点编号以 开启 / 关闭 该节点全流量走 WARP:%b\n\n" "$DIM" "$NC"
        for t in "${tags[@]}"; do
            n=$(jq -r --arg t "$t" '.nodes[$t].name' "$STATE_FILE")
            p=$(jq -r --arg t "$t" '.nodes[$t].port' "$STATE_FILE")
            if _is_node_warp "$t"; then
                st="${GREEN}[已绑定 WARP]${NC}"
            else
                st="${DIM}[默认分流/直连]${NC}"
            fi
            printf "  %b%2d.%b %-18s (:%s)  %b\n" "$GREEN" "$i" "$NC" "$n" "$p" "$st"
            i=$((i + 1))
        done
        print_divider
        printf "  %b输入节点序号切换状态  |  a 全部开启  |  c 全部取消  |  0 返回%b\n" "$DIM" "$NC"
        _read_menu_choice wn_opt "> 选择: "
        local tmp_s tmp_c
        case "$wn_opt" in
            0|'') return 0 ;;
            a|A)
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                jq '.warp_nodes = (.nodes | keys)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 所有节点已绑定走 WARP%b\n' "$GREEN" "$NC"
                sleep 0.6 ;;
            c|C)
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                jq '.warp_nodes = []' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已取消所有节点的 WARP 绑定%b\n' "$GREEN" "$NC"
                sleep 0.6 ;;
            *)
                if [[ "$wn_opt" =~ ^[0-9]+$ ]] && [ "$wn_opt" -ge 1 ] && [ "$wn_opt" -le "${#tags[@]}" ]; then
                    local sel_tag="${tags[$((wn_opt - 1))]}" sel_name
                    sel_name=$(jq -r --arg t "$sel_tag" '.nodes[$t].name' "$STATE_FILE")
                    acquire_lock || continue
                    tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                    if _is_node_warp "$sel_tag"; then
                        jq --arg t "$sel_tag" '.warp_nodes = ([.warp_nodes[]? | select(. != $t)])' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 节点 [%s] 已恢复默认出站%b\n' "$GREEN" "$sel_name" "$NC"
                    else
                        jq --arg t "$sel_tag" '.warp_nodes = (((.warp_nodes // []) + [$t]) | unique)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_node_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 节点 [%s] 已指定走 WARP%b\n' "$GREEN" "$sel_name" "$NC"
                    fi
                    sleep 0.6
                fi ;;
        esac
    done
}

_show_warp_rules_detail() {
    menu_header "WARP 分流规则详情"
    local ep_st mode_st ai_st stream_st c_doms=() w_nodes=() d t n
    _has_warp_outbound && ep_st="${GREEN}已开启 (WireGuard)${NC}" || ep_st="${DIM}未配置${NC}"
    _is_warp_global && mode_st="${YELLOW}全局 WARP${NC}" || mode_st="${CYAN}按规则分流 (默认直连)${NC}"
    _has_warp_ai_rule && ai_st="${GREEN}已启用${NC} (geosite-category-ai-chat-!cn)" || ai_st="${DIM}未启用${NC}"
    _has_warp_stream_rule && stream_st="${GREEN}已启用${NC} (geosite-category-entertainment@!cn)" || stream_st="${DIM}未启用${NC}"
    while IFS= read -r d; do [ -n "$d" ] && c_doms+=("$d"); done < <(_get_warp_custom_domains)
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        n=$(jq -r --arg t "$t" '.nodes[$t].name // empty' "$STATE_FILE")
        [ -n "$n" ] && w_nodes+=("${n}(${t#vless-reality-})")
    done < <(_get_warp_nodes)

    printf "  %b端点状态:%b %b  |  %b出站模式:%b %b\n" "$CYAN" "$NC" "$ep_st" "$CYAN" "$NC" "$mode_st"
    print_divider
    printf "  1. %b指定节点分流:%b %s\n" "$BOLD" "$NC" "${w_nodes[*]:-无}"
    printf "  2. %bAI 智能分流 :%b %b\n" "$BOLD" "$NC" "$ai_st"
    printf "  3. %b流媒体分流  :%b %b\n" "$BOLD" "$NC" "$stream_st"
    printf "  4. %b自定义域名  :%b %s\n" "$BOLD" "$NC" "${c_doms[*]:-无}"
    print_divider
    pause_for_enter
}

_test_warp_connectivity() {
    printf '\n%b>>> 测试 WARP 连通性...%b\n' "$CYAN" "$NC"
    _has_warp_outbound || { printf '%b[!] 请先接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; return 1; }
    local ep_json test_port=15891 tmp_test test_pid trace_res ip colo warp_flag
    ep_json=$(jq -c '.endpoints[]? | select(.tag == "warp-out")' "$CONFIG_FILE" 2>/dev/null)
    [ -n "$ep_json" ] || { printf '%b[!] 未找到 warp-out 端点%b\n' "$RED" "$NC"; pause_for_enter; return 1; }

    tmp_test=$(mktemp /tmp/sbx_test_warp_XXXXXX.json)
    jq -n --argjson ep "$ep_json" --argjson port "$test_port" '{
      "log": { "level": "warn" }, "endpoints": [$ep],
      "inbounds": [{ "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $port }],
      "outbounds": [{ "type": "direct", "tag": "direct" }],
      "route": { "rules": [{ "outbound": "warp-out" }] }
    }' > "$tmp_test"

    "$BIN_FILE" run -c "$tmp_test" >/dev/null 2>&1 &
    test_pid=$!; sleep 1.6
    trace_res=$(curl -x "socks5h://127.0.0.1:${test_port}" -s --connect-timeout 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    kill "$test_pid" 2>/dev/null || true; rm -f "$tmp_test"

    [ -n "$trace_res" ] || { printf '%b[!] WARP 连接超时%b\n' "$RED" "$NC"; pause_for_enter; return 1; }
    ip=$(echo "$trace_res" | awk -F= '/^ip=/{print $2}')
    colo=$(echo "$trace_res" | awk -F= '/^colo=/{print $2}')
    warp_flag=$(echo "$trace_res" | awk -F= '/^warp=/{print $2}')
    printf "  %b状态:%b %b连通%b  |  %bIP:%b %s  |  %b节点:%b %s  |  %bWARP:%b %s\n" \
        "$CYAN" "$NC" "$GREEN" "$NC" "$CYAN" "$NC" "${ip:-未知}" "$CYAN" "$NC" "${colo:-未知}" "$CYAN" "$NC" "${warp_flag:-未知}"
    pause_for_enter
}

_toggle_geosite_rule() {
    local r_tag="$1" r_name="$2" r_file="$3"
    _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; return 1; }
    acquire_lock || return 1
    local tmp_c
    tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
    if jq -e --arg t "$r_tag" '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == $t or ((.rule_set? // []) | index($t))))' "$CONFIG_FILE" >/dev/null 2>&1; then
        jq --arg t "$r_tag" '
          .route.rule_set = [.route.rule_set[]? | select(.tag != $t)] |
          .route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.rule_set != $t and ((.rule_set? // []) | index($t) == null)))]
        ' "$CONFIG_FILE" > "$tmp_c"
        sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] %s 已关闭%b\n' "$GREEN" "$r_name" "$NC"
    else
        jq --arg t "$r_tag" --arg url "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${r_file}" '
          .route.rule_set = ([.route.rule_set[]? | select(.tag != $t)] + [{
            "tag": $t, "type": "remote", "format": "binary", "url": $url, "download_detour": "direct"
          }]) |
          .route.rules = ([.route.rules[]? | select(.outbound != "warp-out" or (.rule_set != $t and ((.rule_set? // []) | index($t) == null)))] + [{
            "action": "route", "rule_set": $t, "outbound": "warp-out"
          }])
        ' "$CONFIG_FILE" > "$tmp_c"
        sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] %s 已开启%b\n' "$GREEN" "$r_name" "$NC"
    fi
    pause_for_enter
}

manage_warp() {
    while true; do
        menu_header "Cloudflare WARP 出口与分流"
        init_sbx_config
        local warp_st mode_st ai_tag stream_tag dom_cnt node_cnt
        _has_warp_outbound && warp_st="${GREEN}已开启${NC}" || warp_st="${DIM}未配置${NC}"
        _is_warp_global && mode_st="${YELLOW}全局 WARP${NC}" || mode_st="${CYAN}分流模式${NC}"
        _has_warp_ai_rule && ai_tag="${GREEN}开${NC}" || ai_tag="${DIM}关${NC}"
        _has_warp_stream_rule && stream_tag="${GREEN}开${NC}" || stream_tag="${DIM}关${NC}"
        dom_cnt=$(jq '.warp_custom_domains | length' "$STATE_FILE" 2>/dev/null || echo 0)
        node_cnt=$(jq '[.warp_nodes[]? as $t | select(.nodes[$t] != null)] | length' "$STATE_FILE" 2>/dev/null || echo 0)

        printf "  %bWARP:%b %b  |  %b模式:%b %b\n" "$CYAN" "$NC" "$warp_st" "$CYAN" "$NC" "$mode_st"
        printf "  %b分流:%b 节点[%b%s%b] · AI[%b] · 流媒体[%b] · 域名[%b%s%b]\n\n" \
            "$CYAN" "$NC" "$YELLOW" "$node_cnt" "$NC" "$ai_tag" "$stream_tag" "$CYAN" "$dom_cnt" "$NC"

        menu_pair 1 "接入/重置 WARP" 2 "查看规则详情"
        menu_pair 3 "测试 WARP 连通" 4 "全局 WARP 开关"
        print_divider
        menu_pair 5 "指定节点走 WARP" 6 "AI 分流开关"
        menu_pair 7 "流媒体分流开关" 8 "添加分流域名"
        menu_pair 9 "删除分流域名" 10 "彻底移除 WARP"
        menu_single 0 "返回"

        _read_menu_choice warp_opt "> 选择 [0-10]: "
        case "$warp_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service
                printf '\n%b>>> 注册 Cloudflare WARP...%b\n' "$CYAN" "$NC"
                local wg_keys priv_key pub_key install_id reg_payload reg_res v4_addr v6_addr peer_pub addr_arr warp_endpoint tmp_c
                wg_keys=$("$BIN_FILE" generate wg-keypair 2>/dev/null)
                priv_key=$(echo "$wg_keys" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
                pub_key=$(echo "$wg_keys" | awk '/PublicKey:/{print $2}' | tr -d '\r')
                [ -n "$priv_key" ] && [ -n "$pub_key" ] || { printf '%b[!] 生成密钥失败%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                install_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || openssl rand -hex 16)
                reg_payload=$(jq -n --arg key "$pub_key" --arg iid "$install_id" \
                  '{key: $key, install_id: $iid, fcm_token: "", tos: (now | todateiso8601), model: "Linux", serial_number: $iid, locale: "en_US"}')
                reg_res=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
                  -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.3-2158" -H "Content-Type: application/json" \
                  -d "$reg_payload" --connect-timeout 10 2>/dev/null)

                v4_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v4 // "172.16.0.2"')
                v6_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v6 // empty')
                peer_pub=$(echo "$reg_res" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
                [ -n "$v6_addr" ] && addr_arr="[\"${v4_addr}/32\", \"${v6_addr}/128\"]" || addr_arr="[\"${v4_addr}/32\"]"

                warp_endpoint=$(jq -n --arg priv "$priv_key" --arg pub "$peer_pub" --argjson addrs "$addr_arr" '{
                  "type": "wireguard", "tag": "warp-out", "address": $addrs, "private_key": $priv,
                  "peers": [{ "address": "162.159.192.8", "port": 2408, "public_key": $pub, "allowed_ips": ["0.0.0.0/0", "::/0"] }]
                }')
                tmp_c=$(mktemp /tmp/sbx_warp_XXXXXX)
                jq --argjson ep "$warp_endpoint" '
                  .endpoints = ([.endpoints[]? | select(.tag != "warp-out")] + [$ep]) |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] WARP 端点已就绪 (%s)%b\n' "$GREEN" "$v4_addr" "$NC"
                pause_for_enter ;;
            2) _show_warp_rules_detail ;;
            3) _test_warp_connectivity ;;
            4)
                _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                acquire_lock || continue
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_global_XXXXXX)
                if _is_warp_global; then
                    jq '.route.final = "direct"' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] 已切换为【分流模式 (默认直连)】%b\n' "$GREEN" "$NC"
                else
                    confirm_action "开启全局 WARP (所有出站默认走 WARP)？" || continue
                    jq '
                      .route.rules = (
                        (if ([.route.rules[]? | select(.ip_is_private == true)] | length) == 0 then
                          [{ "action": "route", "ip_is_private": true, "outbound": "direct" }]
                        else [] end) + .route.rules
                      ) | .route.final = "warp-out"
                    ' "$CONFIG_FILE" > "$tmp_c"
                    sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] 已开启【全局 WARP 出口】%b\n' "$GREEN" "$NC"
                fi
                pause_for_enter ;;
            5) _manage_warp_nodes ;;
            6) _toggle_geosite_rule "geosite-ai" "AI 智能分流" "geosite-category-ai-chat-!cn.srs" ;;
            7) _toggle_geosite_rule "geosite-stream" "流媒体分流" "geosite-category-entertainment@!cn.srs" ;;
            8)
                _has_warp_outbound || { printf '\n%b[!] 请先选 1 接入 WARP%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                local raw_doms new_doms=() d tmp_s tmp_c json_arr
                read -rp "  输入分流域名 (空格分隔, 如 claude.ai reddit.com): " raw_doms
                raw_doms=$(echo "$raw_doms" | tr -d '\r')
                [ -n "$raw_doms" ] || continue
                for d in $raw_doms; do
                    d=$(echo "$d" | tr '[:upper:]' '[:lower:]' | sed -E 's|^https?://||; s|/.*$||')
                    [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && new_doms+=("$d")
                done
                [ "${#new_doms[@]}" -gt 0 ] || { printf '%b[!] 域名格式无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                acquire_lock || continue
                tmp_s=$(mktemp /tmp/sbx_state_XXXXXX); tmp_c=$(mktemp /tmp/sbx_cfg_XXXXXX)
                json_arr=$(printf '%s\n' "${new_doms[@]}" | jq -R . | jq -s .)
                jq --argjson new "$json_arr" '.warp_custom_domains = ((.warp_custom_domains // []) + $new | unique)' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已添加: %s%b\n' "$GREEN" "${new_doms[*]}" "$NC"
                pause_for_enter ;;
            9)
                local cur_doms=() d idx=1 del_choice tmp_s tmp_c
                while IFS= read -r d; do [ -n "$d" ] && cur_doms+=("$d"); done < <(_get_warp_custom_domains)
                [ "${#cur_doms[@]}" -gt 0 ] || { printf '\n%b[!] 暂无自定义域名%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                printf '\n'
                for d in "${cur_doms[@]}"; do printf "  %b%2d.%b %s\n" "$CYAN" "$idx" "$NC" "$d"; idx=$((idx + 1)); done
                read -rp "  输入编号删除 (a 清空全部, 0 返回): " del_choice; del_choice="${del_choice// /}"
                case "$del_choice" in
                    0|'') continue ;;
                    a|A)
                        confirm_action "清空所有自定义分流域名？" || continue
                        acquire_lock || continue
                        tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                        jq '.warp_custom_domains = []' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                        _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                        sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已清空%b\n' "$GREEN" "$NC"
                        pause_for_enter ;;
                    *)
                        if [[ "$del_choice" =~ ^[0-9]+$ ]] && [ "$del_choice" -ge 1 ] && [ "$del_choice" -le "${#cur_doms[@]}" ]; then
                            local target_dom="${cur_doms[$((del_choice - 1))]}"
                            acquire_lock || continue
                            tmp_s=$(mktemp /tmp/sbx_s_XXXXXX); tmp_c=$(mktemp /tmp/sbx_c_XXXXXX)
                            jq --arg d "$target_dom" '.warp_custom_domains = [.warp_custom_domains[]? | select(. != $d)]' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                            _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                            sbx_apply_config_safe "$tmp_c" && printf '%b[OK] 已删除: %s%b\n' "$GREEN" "$target_dom" "$NC"
                            pause_for_enter
                        fi ;;
                esac ;;
            10)
                confirm_action "彻底移除 WARP 出口及全部关联规则？" || continue
                acquire_lock || continue
                local tmp_c tmp_s
                tmp_c=$(mktemp /tmp/sbx_warp_del_XXXXXX); tmp_s=$(mktemp /tmp/sbx_state_del_XXXXXX)
                jq '
                  .endpoints = [.endpoints[]? | select(.tag != "warp-out")] |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")] |
                  .route.final = "direct" |
                  .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-ai" and .tag != "geosite-stream")] |
                  .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"
                jq '.warp_custom_domains = [] | .warp_nodes = []' "$STATE_FILE" > "$tmp_s" 2>/dev/null && mv "$tmp_s" "$STATE_FILE"
                sbx_apply_config_safe "$tmp_c" && printf '\n%b[OK] WARP 及分流规则已移除%b\n' "$GREEN" "$NC"
                pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}
