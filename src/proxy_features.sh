# ==================== 端口转发与 WARP 出口分流 ====================

# ---------- TCP / UDP 端口转发 ----------
manage_forward() {
    while true; do
        menu_header "TCP / UDP 端口转发"
        init_sbx_config

        local fwd_rules=() i=1
        while IFS= read -r tag; do
            [ -n "$tag" ] || continue
            fwd_rules+=("$tag")
        done < <(jq -r '.inbounds[] | select(.type == "direct") | .tag' "$CONFIG_FILE" 2>/dev/null)

        printf "  %b当前转发规则列表:%b\n" "$CYAN" "$NC"
        if [ ${#fwd_rules[@]} -eq 0 ]; then
            printf "    %b暂无端口转发规则%b\n\n" "$DIM" "$NC"
        else
            for tag in "${fwd_rules[@]}"; do
                local lp dest_ip dest_port
                lp=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .listen_port' "$CONFIG_FILE")
                dest_ip=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_address' "$CONFIG_FILE")
                dest_port=$(jq -r --arg t "$tag" '.inbounds[] | select(.tag == $t) | .override_port' "$CONFIG_FILE")
                printf "  %b%d.%b 本机端口 %b%s%b -> 目标 %s:%s\n" "$GREEN" "$i" "$NC" "$YELLOW" "$lp" "$NC" "$dest_ip" "$dest_port"
                i=$((i + 1))
            done
            printf '\n'
        fi

        menu_single 1 "添加新的端口转发"
        menu_single 2 "删除端口转发规则"
        menu_single 0 "返回主菜单"

        _read_menu_choice fwd_opt "> 请选择操作 [0-2]: "
        case "$fwd_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service

                local local_port dest_host dest_port
                printf '\n'
                read -rp "  请输入本机监听端口: " local_port
                local_port="${local_port// /}"
                [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -ge 1 ] && [ "$local_port" -le 65535 ] || {
                    printf '%b[!] 监听端口不合法。%b\n' "$RED" "$NC"; pause_for_enter; continue;
                }

                read -rp "  请输入目标 IP 或域名: " dest_host
                dest_host="${dest_host// /}"
                [ -n "$dest_host" ] || { printf '%b[!] 目标地址不能为空。%b\n' "$RED" "$NC"; pause_for_enter; continue; }

                read -rp "  请输入目标端口: " dest_port
                dest_port="${dest_port// /}"
                [[ "$dest_port" =~ ^[0-9]+$ ]] && [ "$dest_port" -ge 1 ] && [ "$dest_port" -le 65535 ] || {
                    printf '%b[!] 目标端口不合法。%b\n' "$RED" "$NC"; pause_for_enter; continue;
                }

                local fwd_tag="fwd-${local_port}"
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_fwd_XXXXXX)
                jq --arg tag "$fwd_tag" \
                   --argjson lp "$local_port" \
                   --arg host "$dest_host" \
                   --argjson dp "$dest_port" \
                   '.inbounds = [.inbounds[] | select(.tag != $tag)] + [{
                      "type": "direct",
                      "tag": $tag,
                      "listen": "::",
                      "listen_port": $lp,
                      "override_address": $host,
                      "override_port": $dp
                   }]' "$CONFIG_FILE" > "$tmp_c"

                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi

                printf '\n%b[成功] 端口转发已添加: 本机 %s -> %s:%s%b\n' "$GREEN" "$local_port" "$dest_host" "$dest_port" "$NC"
                pause_for_enter
                ;;
            2)
                [ ${#fwd_rules[@]} -gt 0 ] || { pause_for_enter; continue; }
                printf '\n'
                read -rp "  请输入要删除的转发规则编号 [1-${#fwd_rules[@]}]: " idx
                idx="${idx// /}"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#fwd_rules[@]}" ]; then
                    local sel_tag="${fwd_rules[$((idx - 1))]}"
                    if confirm_action "确认删除规则: ${sel_tag}？"; then
                        acquire_lock || continue
                        local tmp_c
                        tmp_c=$(mktemp /tmp/sbx_fwd_del_XXXXXX)
                        jq --arg tag "$sel_tag" '.inbounds = [.inbounds[] | select(.tag != $tag)]' "$CONFIG_FILE" > "$tmp_c"
                        if ! sbx_apply_config_safe "$tmp_c"; then
                            pause_for_enter
                            continue
                        fi
                        printf '%b[成功] 规则已删除！%b\n' "$GREEN" "$NC"
                        pause_for_enter
                    fi
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
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
    local fin
    fin=$(jq -r '.route.final // empty' "$CONFIG_FILE" 2>/dev/null)
    [ "$fin" = "warp-out" ]
}

_has_warp_ai_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-ai" or ((.rule_set? // []) | index("geosite-ai")) or ((.domain_suffix? // []) | index("openai.com"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_has_warp_stream_rule() {
    [ -f "$CONFIG_FILE" ] || return 1
    jq -e '.route.rules[]? | select(.outbound == "warp-out" and (.rule_set == "geosite-stream" or ((.rule_set? // []) | index("geosite-stream")) or ((.domain_suffix? // []) | index("netflix.com"))))' "$CONFIG_FILE" >/dev/null 2>&1
}

_get_warp_custom_domains() {
    [ -f "$STATE_FILE" ] || return 0
    jq -r '.warp_custom_domains[]? // empty' "$STATE_FILE" 2>/dev/null
}

_sync_warp_custom_rules() {
    local cfg_in="$1" cfg_out="$2"
    local doms_json
    doms_json=$(jq -c '.warp_custom_domains // []' "$STATE_FILE" 2>/dev/null || echo "[]")

    if [ "$doms_json" = "[]" ] || [ -z "$doms_json" ]; then
        jq '
          .route.rules = [
            .route.rules[]? | select(
              .outbound != "warp-out" or
              .rule_set != null or
              ((.domain_suffix? // []) | (index("openai.com") != null or index("netflix.com") != null))
            )
          ]
        ' "$cfg_in" > "$cfg_out"
    else
        jq --argjson doms "$doms_json" '
          .route.rules = [
            .route.rules[]? | select(
              .outbound != "warp-out" or
              .rule_set != null or
              ((.domain_suffix? // []) | (index("openai.com") != null or index("netflix.com") != null))
            )
          ] + [{
            "action": "route",
            "domain_suffix": $doms,
            "outbound": "warp-out"
          }]
        ' "$cfg_in" > "$cfg_out"
    fi
}

_show_warp_rules_detail() {
    menu_header "当前 WARP 路由与分流规则明细"
    print_divider

    local ep_status mode_str
    if _has_warp_outbound; then
        ep_status="${GREEN}已配置开启 (WireGuard)${NC}"
    else
        ep_status="${DIM}未配置 / 已关闭${NC}"
    fi

    if _is_warp_global; then
        mode_str="${YELLOW}${BOLD}全局 WARP 出口 (所有出站流量走 WARP)${NC}"
    else
        mode_str="${CYAN}分流模式 (仅规则匹配流量走 WARP，其余直连)${NC}"
    fi

    printf "  %bWARP 端点状态:%b  %b\n" "$CYAN" "$NC" "$ep_status"
    printf "  %b当前出站模式:%b  %b\n" "$CYAN" "$NC" "$mode_str"
    print_divider

    printf "  %b[ 分流规则清单 ]%b\n\n" "$PURPLE$BOLD" "$NC"

    # 1. AI 智能分流
    local ai_status
    if _has_warp_ai_rule; then
        ai_status="${GREEN}已启用 (Sing-box 官方上游规则集)${NC}"
    else
        ai_status="${DIM}未启用${NC}"
    fi
    printf "  1. %bAI 智能服务分流%b: %b\n" "$BOLD" "$NC" "$ai_status"
    printf "     上游规则: SagerNet/sing-geosite (category-ai-chat-!cn)\n"
    printf "     覆盖范围: ChatGPT, Claude, Gemini, Copilot, Perplexity, Poe 等\n"
    printf "     目标出口: warp-out\n\n"

    # 2. 流媒体
    local stream_status
    if _has_warp_stream_rule; then
        stream_status="${GREEN}已启用 (Sing-box 官方上游规则集)${NC}"
    else
        stream_status="${DIM}未启用${NC}"
    fi
    printf "  2. %b主流流媒体服务分流%b: %b\n" "$BOLD" "$NC" "$stream_status"
    printf "     上游规则: SagerNet/sing-geosite (category-entertainment@!cn)\n"
    printf "     覆盖范围: Netflix, YouTube, Disney+, Spotify, HBO 等全球主流流媒体\n"
    printf "     目标出口: warp-out\n\n"

    # 3. 自定义域名
    local c_doms=()
    while IFS= read -r d; do
        [ -n "$d" ] && c_doms+=("$d")
    done < <(_get_warp_custom_domains)

    if [ "${#c_doms[@]}" -gt 0 ]; then
        printf "  3. %b自定义域名分流%b: %b已配置 %d 个域名%b\n" "$BOLD" "$NC" "$GREEN" "${#c_doms[@]}" "$NC"
        printf "     域名列表: %s\n" "${c_doms[*]}"
        printf "     目标出口: warp-out\n"
    else
        printf "  3. %b自定义域名分流%b: %b未配置%b\n" "$BOLD" "$NC" "$DIM" "$NC"
        printf "     可通过菜单选项 [8] 随时添加指定域名\n"
    fi

    print_divider
    pause_for_enter
}

_test_warp_connectivity() {
    printf '\n%b>>> 正在测试 Cloudflare WARP 出口连通性...%b\n' "$CYAN" "$NC"
    if ! _has_warp_outbound; then
        printf '%b[!] WARP 出口未配置，请先接入 WARP。%b\n' "$YELLOW" "$NC"
        pause_for_enter; return 1;
    fi

    local ep_json
    ep_json=$(jq -c '.endpoints[]? | select(.tag == "warp-out")' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$ep_json" ]; then
        printf '%b[!] 未找到 warp-out 端点配置。%b\n' "$RED" "$NC"
        pause_for_enter; return 1;
    fi

    local test_port=15891
    local tmp_test
    tmp_test=$(mktemp /tmp/sbx_test_warp_XXXXXX.json)
    jq -n \
      --argjson ep "$ep_json" \
      --argjson port "$test_port" \
      '{
        "log": { "level": "warn" },
        "endpoints": [$ep],
        "inbounds": [{ "type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": $port }],
        "outbounds": [{ "type": "direct", "tag": "direct" }],
        "route": { "rules": [{ "outbound": "warp-out" }] }
      }' > "$tmp_test"

    "$BIN_FILE" run -c "$tmp_test" >/dev/null 2>&1 &
    local test_pid=$!
    sleep 1.8

    local trace_res
    trace_res=$(curl -x "socks5h://127.0.0.1:${test_port}" -s --connect-timeout 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    kill "$test_pid" 2>/dev/null || true
    rm -f "$tmp_test"

    if [ -z "$trace_res" ]; then
        printf '%b[!] WARP 出口连接超时，请检查服务器海外 UDP 2408 端口网络连通性。%b\n' "$RED" "$NC"
        pause_for_enter; return 1;
    fi

    local ip colo warp_flag
    ip=$(echo "$trace_res" | awk -F= '/^ip=/{print $2}')
    colo=$(echo "$trace_res" | awk -F= '/^colo=/{print $2}')
    warp_flag=$(echo "$trace_res" | awk -F= '/^warp=/{print $2}')

    printf '\n  %b出口状态:%b  %b正常连通%b\n' "$CYAN" "$NC" "$GREEN$BOLD" "$NC"
    printf '  %b出口 IP:%b   %s\n' "$CYAN" "$NC" "${ip:-未知}"
    printf '  %b数据中心:%b  %s\n' "$CYAN" "$NC" "${colo:-未知}"
    printf '  %bWARP 状态:%b %s\n\n' "$CYAN" "$NC" "${warp_flag:-未知}"
    pause_for_enter
}

manage_warp() {
    while true; do
        menu_header "Cloudflare WARP 出口与分流"
        init_sbx_config

        local warp_status mode_status rule_summary
        if _has_warp_outbound; then
            warp_status="${GREEN}已配置开启 (WireGuard)${NC}"
        else
            warp_status="${DIM}未配置 / 已关闭${NC}"
        fi

        if _is_warp_global; then
            mode_status="${YELLOW}${BOLD}全局 WARP (所有流量走 WARP)${NC}"
        else
            mode_status="${CYAN}分流模式 (仅规则匹配流量走 WARP)${NC}"
        fi

        local ai_tag stream_tag custom_count
        _has_warp_ai_rule && ai_tag="${GREEN}开${NC}" || ai_tag="${DIM}关${NC}"
        _has_warp_stream_rule && stream_tag="${GREEN}开${NC}" || stream_tag="${DIM}关${NC}"
        custom_count=$(jq '.warp_custom_domains | length' "$STATE_FILE" 2>/dev/null || echo 0)
        rule_summary="AI分流: [${ai_tag}] · 流媒体: [${stream_tag}] · 自定义: [${CYAN}${custom_count}${NC}个]"

        printf "  %bWARP 端点状态:%b %b\n" "$CYAN" "$NC" "$warp_status"
        printf "  %b当前出站模式:%b %b\n" "$CYAN" "$NC" "$mode_status"
        printf "  %b当前规则状态:%b %b\n\n" "$CYAN" "$NC" "$rule_summary"

        printf "  %b[ 基础与状态 ]%b\n" "$PURPLE" "$NC"
        menu_single 1 "接入 / 重新生成 Cloudflare WARP 官方 WireGuard 出口"
        menu_single 2 "查看当前全部分流规则详情"
        menu_single 3 "测试 WARP 出口连通性与 IP 状态"

        printf "\n  %b[ 出口与分流模式 ]%b\n" "$PURPLE" "$NC"
        menu_single 4 "切换为【全局 WARP 出口】(所有未被私有地址绕过的流量走 WARP)"
        menu_single 5 "切换为【默认直连出口】(仅规则匹配流量走 WARP)"

        printf "\n  %b[ 分流规则管理 (上游规则集+自定义) ]%b\n" "$PURPLE" "$NC"
        menu_single 6 "开启 / 关闭【AI 智能分流】(ChatGPT/Claude/Gemini/Copilot等)"
        menu_single 7 "开启 / 关闭【主流流媒体分流】(Netflix/YouTube/Disney+等)"
        menu_single 8 "添加【自定义域名分流】(支持批量输入，如: claude.ai anthropic.com)"
        menu_single 9 "查看并删除指定的自定义分流域名"

        printf "\n  %b[ 清理与返回 ]%b\n" "$PURPLE" "$NC"
        menu_single 10 "彻底移除 WARP 出口与所有关联规则"
        menu_single 0 "返回主菜单"

        _read_menu_choice warp_opt "> 请选择操作 [0-10]: "
        case "$warp_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service

                printf '\n%b>>> 正在向 Cloudflare WARP 官方 API 注册设备与密钥...%b\n' "$CYAN" "$NC"
                local wg_keys priv_key pub_key
                wg_keys=$("$BIN_FILE" generate wg-keypair 2>/dev/null)
                priv_key=$(echo "$wg_keys" | awk '/PrivateKey:/{print $2}' | tr -d '\r')
                pub_key=$(echo "$wg_keys" | awk '/PublicKey:/{print $2}' | tr -d '\r')

                if [ -z "$priv_key" ] || [ -z "$pub_key" ]; then
                    printf '%b[!] 生成 WireGuard 密钥对失败，请检查 sing-box 核心。%b\n' "$RED" "$NC"
                    pause_for_enter; continue;
                fi

                local install_id
                install_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' || openssl rand -hex 16)
                local reg_payload reg_res
                reg_payload=$(jq -n --arg key "$pub_key" --arg iid "$install_id" \
                  '{key: $key, install_id: $iid, fcm_token: "", tos: (now | todateiso8601), model: "Linux", serial_number: $iid, locale: "en_US"}')

                reg_res=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
                  -H "User-Agent: okhttp/3.12.1" \
                  -H "CF-Client-Version: a-6.3-2158" \
                  -H "Content-Type: application/json" \
                  -d "$reg_payload" --connect-timeout 10 2>/dev/null)

                local v4_addr v6_addr peer_pub peer_ip
                v4_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v4 // empty')
                v6_addr=$(echo "$reg_res" | jq -r '.config.interface.addresses.v6 // empty')
                peer_pub=$(echo "$reg_res" | jq -r '.config.peers[0].public_key // "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="')
                peer_ip="162.159.192.8"

                [ -n "$v4_addr" ] || v4_addr="172.16.0.2"

                local addr_arr
                if [ -n "$v6_addr" ]; then
                    addr_arr="[\"${v4_addr}/32\", \"${v6_addr}/128\"]"
                else
                    addr_arr="[\"${v4_addr}/32\"]"
                fi

                local warp_endpoint
                warp_endpoint=$(jq -n \
                  --arg priv "$priv_key" \
                  --arg pub "$peer_pub" \
                  --arg pip "$peer_ip" \
                  --argjson addrs "$addr_arr" \
                  '{
                    "type": "wireguard",
                    "tag": "warp-out",
                    "address": $addrs,
                    "private_key": $priv,
                    "peers": [
                      {
                        "address": $pip,
                        "port": 2408,
                        "public_key": $pub,
                        "allowed_ips": ["0.0.0.0/0", "::/0"]
                      }
                    ]
                  }')

                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_warp_XXXXXX)
                jq --argjson ep "$warp_endpoint" '
                  .endpoints = ([.endpoints[]? | select(.tag != "warp-out")] + [$ep]) |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c"

                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi

                printf '\n%b[成功] Cloudflare WARP 官方设备注册成功，WireGuard 端点已接入！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            2)
                _show_warp_rules_detail
                ;;
            3)
                _test_warp_connectivity
                ;;
            4)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                if _is_warp_global; then
                    printf '\n%b[提示] 当前已经是全局 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                if confirm_action "确认将出站模式切换为【全局 WARP 出口】？(所有流量默认走 WARP，私有内网 IP 自动直连)"; then
                    acquire_lock || continue
                    local tmp_c
                    tmp_c=$(mktemp /tmp/sbx_global_XXXXXX)
                    jq '
                      .route.rules = (
                        (if ([.route.rules[]? | select(.ip_is_private == true)] | length) == 0 then
                          [{ "action": "route", "ip_is_private": true, "outbound": "direct" }]
                        else [] end) + .route.rules
                      ) |
                      .route.final = "warp-out"
                    ' "$CONFIG_FILE" > "$tmp_c"
                    if ! sbx_apply_config_safe "$tmp_c"; then
                        pause_for_enter; continue;
                    fi
                    printf '\n%b[成功] 已切换为【全局 WARP 出口】！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            5)
                if ! _is_warp_global; then
                    printf '\n%b[提示] 当前已经是默认直连模式。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                if confirm_action "确认切换为【默认直连出口】？(仅规则匹配的域名走 WARP)"; then
                    acquire_lock || continue
                    local tmp_c
                    tmp_c=$(mktemp /tmp/sbx_direct_XXXXXX)
                    jq '.route.final = "direct"' "$CONFIG_FILE" > "$tmp_c"
                    if ! sbx_apply_config_safe "$tmp_c"; then
                        pause_for_enter; continue;
                    fi
                    printf '\n%b[成功] 已切换为【默认直连出口】！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            6)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                acquire_lock || continue
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                if _has_warp_ai_rule; then
                    # 关闭 AI 分流
                    jq '
                      .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-ai")] |
                      .route.rules = [.route.rules[]? | select(
                        .outbound != "warp-out" or
                        (.rule_set != "geosite-ai" and ((.rule_set? // []) | index("geosite-ai") == null) and ((.domain_suffix? // []) | index("openai.com") == null))
                      )]
                    ' "$CONFIG_FILE" > "$tmp_c"
                    if sbx_apply_config_safe "$tmp_c"; then
                        printf '\n%b[成功] AI 智能分流规则已关闭！%b\n' "$GREEN" "$NC"
                    fi
                else
                    # 开启 AI 分流 (接入 Sing-box 上游 SagerNet/sing-geosite)
                    printf '\n%b>>> 正在注入 Sing-box 上游 AI 官方规则集 (category-ai-chat-!cn)...%b\n' "$CYAN" "$NC"
                    jq '
                      .route.rule_set = ([.route.rule_set[]? | select(.tag != "geosite-ai")] + [{
                        "tag": "geosite-ai",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-chat-!cn.srs",
                        "download_detour": "direct"
                      }]) |
                      .route.rules = ([.route.rules[]? | select(
                        .outbound != "warp-out" or
                        (.rule_set != "geosite-ai" and ((.rule_set? // []) | index("geosite-ai") == null) and ((.domain_suffix? // []) | index("openai.com") == null))
                      )] + [{
                        "action": "route",
                        "rule_set": "geosite-ai",
                        "outbound": "warp-out"
                      }])
                    ' "$CONFIG_FILE" > "$tmp_c"
                    if sbx_apply_config_safe "$tmp_c"; then
                        printf '\n%b[成功] AI 智能分流规则已生效 (全面支持 ChatGPT/Claude/Gemini/Copilot 等)！%b\n' "$GREEN" "$NC"
                    fi
                fi
                pause_for_enter
                ;;
            7)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                acquire_lock || continue
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                if _has_warp_stream_rule; then
                    # 关闭 流媒体分流
                    jq '
                      .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-stream")] |
                      .route.rules = [.route.rules[]? | select(
                        .outbound != "warp-out" or
                        (.rule_set != "geosite-stream" and ((.rule_set? // []) | index("geosite-stream") == null) and ((.domain_suffix? // []) | index("netflix.com") == null))
                      )]
                    ' "$CONFIG_FILE" > "$tmp_c"
                    if sbx_apply_config_safe "$tmp_c"; then
                        printf '\n%b[成功] 主流流媒体分流规则已关闭！%b\n' "$GREEN" "$NC"
                    fi
                else
                    # 开启 流媒体分流 (接入 Sing-box 上游 SagerNet/sing-geosite)
                    printf '\n%b>>> 正在注入 Sing-box 上游流媒体官方规则集 (category-entertainment@!cn)...%b\n' "$CYAN" "$NC"
                    jq '
                      .route.rule_set = ([.route.rule_set[]? | select(.tag != "geosite-stream")] + [{
                        "tag": "geosite-stream",
                        "type": "remote",
                        "format": "binary",
                        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-entertainment@!cn.srs",
                        "download_detour": "direct"
                      }]) |
                      .route.rules = ([.route.rules[]? | select(
                        .outbound != "warp-out" or
                        (.rule_set != "geosite-stream" and ((.rule_set? // []) | index("geosite-stream") == null) and ((.domain_suffix? // []) | index("netflix.com") == null))
                      )] + [{
                        "action": "route",
                        "rule_set": "geosite-stream",
                        "outbound": "warp-out"
                      }])
                    ' "$CONFIG_FILE" > "$tmp_c"
                    if sbx_apply_config_safe "$tmp_c"; then
                        printf '\n%b[成功] 主流流媒体分流规则已生效 (全面支持 Netflix/YouTube/Disney+/Spotify 等)！%b\n' "$GREEN" "$NC"
                    fi
                fi
                pause_for_enter
                ;;
            8)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                printf '\n%b请输入需要引导走 WARP 的域名 (支持多个域名，以空格分隔):%b\n' "$CYAN" "$NC"
                printf '%b示例: claude.ai anthropic.com reddit.com%b\n' "$DIM" "$NC"
                read -rp "  输入域名: " raw_doms
                raw_doms=$(echo "$raw_doms" | tr -d '\r')
                if [ -z "$raw_doms" ]; then
                    printf '%b[!] 输入为空，已取消。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi

                local new_doms=()
                for d in $raw_doms; do
                    # 简单清洗: 转小写，去 http:// 或 https://，去末尾斜线
                    d=$(echo "$d" | tr '[:upper:]' '[:lower:]' | sed -E 's|^https?://||; s|/.*$||')
                    [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && new_doms+=("$d")
                done

                if [ "${#new_doms[@]}" -eq 0 ]; then
                    printf '%b[!] 未检测到有效的域名格式。%b\n' "$RED" "$NC"
                    pause_for_enter; continue;
                fi

                acquire_lock || continue
                local tmp_s
                tmp_s=$(mktemp /tmp/sbx_state_XXXXXX)
                local json_arr
                json_arr=$(printf '%s\n' "${new_doms[@]}" | jq -R . | jq -s .)
                jq --argjson new "$json_arr" '
                  .warp_custom_domains = ((.warp_custom_domains // []) + $new | unique)
                ' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"

                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_cfg_sync_XXXXXX)
                _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter; continue;
                fi
                printf '\n%b[成功] 已成功添加自定义分流域名：%s%b\n' "$GREEN" "${new_doms[*]}" "$NC"
                pause_for_enter
                ;;
            9)
                local cur_doms=()
                while IFS= read -r d; do
                    [ -n "$d" ] && cur_doms+=("$d")
                done < <(_get_warp_custom_domains)

                if [ "${#cur_doms[@]}" -eq 0 ]; then
                    printf '\n%b[提示] 当前尚未配置任何自定义分流域名。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi

                menu_header "删除自定义分流域名"
                printf "  当前已配置的自定义域名列表:\n\n"
                local idx=1
                for d in "${cur_doms[@]}"; do
                    printf "   %b%2d.%b %s\n" "$CYAN" "$idx" "$NC" "$d"
                    ((idx++))
                done
                print_divider
                printf "  %b输入序号删除指定域名，输入 a 清空全部，输入 0 返回%b\n" "$DIM" "$NC"
                read -rp "  请选择: " del_choice
                del_choice=$(echo "$del_choice" | tr -d ' \r\n')

                case "$del_choice" in
                    0|'') continue ;;
                    a|A)
                        if confirm_action "确认清空所有自定义分流域名？"; then
                            acquire_lock || continue
                            local tmp_s tmp_c
                            tmp_s=$(mktemp /tmp/sbx_state_XXXXXX)
                            jq '.warp_custom_domains = []' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                            tmp_c=$(mktemp /tmp/sbx_cfg_sync_XXXXXX)
                            _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                            sbx_apply_config_safe "$tmp_c"
                            printf '\n%b[成功] 已清空全部自定义分流域名！%b\n' "$GREEN" "$NC"
                            pause_for_enter
                        fi
                        ;;
                    *)
                        if [[ "$del_choice" =~ ^[0-9]+$ ]] && [ "$del_choice" -ge 1 ] && [ "$del_choice" -le "${#cur_doms[@]}" ]; then
                            local target_dom="${cur_doms[$((del_choice - 1))]}"
                            acquire_lock || continue
                            local tmp_s tmp_c
                            tmp_s=$(mktemp /tmp/sbx_state_XXXXXX)
                            jq --arg d "$target_dom" '.warp_custom_domains = [.warp_custom_domains[]? | select(. != $d)]' "$STATE_FILE" > "$tmp_s" && mv "$tmp_s" "$STATE_FILE"
                            tmp_c=$(mktemp /tmp/sbx_cfg_sync_XXXXXX)
                            _sync_warp_custom_rules "$CONFIG_FILE" "$tmp_c"
                            sbx_apply_config_safe "$tmp_c"
                            printf '\n%b[成功] 已删除自定义域名: %s%b\n' "$GREEN" "$target_dom" "$NC"
                            pause_for_enter
                        else
                            printf '\n%b[!] 序号无效。%b\n' "$RED" "$NC"
                            pause_for_enter
                        fi
                        ;;
                esac
                ;;
            10)
                if confirm_action "彻底移除 WARP 出口、全局 WARP 设置与全部关联分流规则？"; then
                    acquire_lock || continue
                    local tmp_c tmp_s
                    tmp_c=$(mktemp /tmp/sbx_warp_del_XXXXXX)
                    jq '
                      .endpoints = [.endpoints[]? | select(.tag != "warp-out")] |
                      .outbounds = [.outbounds[]? | select(.tag != "warp-out")] |
                      .route.final = "direct" |
                      .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-ai" and .tag != "geosite-stream")] |
                      .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]
                    ' "$CONFIG_FILE" > "$tmp_c"

                    tmp_s=$(mktemp /tmp/sbx_state_del_XXXXXX)
                    jq '.warp_custom_domains = []' "$STATE_FILE" > "$tmp_s" 2>/dev/null && mv "$tmp_s" "$STATE_FILE"

                    if ! sbx_apply_config_safe "$tmp_c"; then
                        pause_for_enter
                        continue
                    fi
                    printf '\n%b[成功] WARP 出口、全局设置与全部分流规则已彻底清除！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}
