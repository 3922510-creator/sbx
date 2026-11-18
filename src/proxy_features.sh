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
_warp_entry() {
    jq -ec 'first(
      (.endpoints[]? | select(.tag == "warp-out") | {endpoints: [.]}),
      (.outbounds[]? | select(.tag == "warp-out") | {outbounds: [.]})
    )' "$CONFIG_FILE" 2>/dev/null
}

_has_warp_outbound() { _warp_entry >/dev/null; }

_warp_family() {
    jq -er '(.endpoints[0].address // .outbounds[0].local_address // []) | [flatten[] | contains(":")] | unique |
      if . == [false, true] then "dual" elif . == [false] then "ipv4" elif . == [true] then "ipv6" else empty end'
}

_warp_family_label() {
    case "$1" in
        ipv4) printf '仅 IPv4' ;;
        ipv6) printf '仅 IPv6' ;;
        dual) printf 'IPv4 + IPv6' ;;
        *) printf '未知' ;;
    esac
}

_warp_endpoint_for_family() {
    jq -e --arg family "$1" --argjson pool "$2" '
      ($pool | map(select(contains(":") | not))) as $v4 |
      ($pool | map(select(contains(":")))) as $v6 |
      if ($family != "ipv6" and ($v4 | length) == 0) or ($family != "ipv4" and ($v6 | length) == 0) then
        error("WARP 未注册所选地址族，请先重新接入")
      elif $family == "ipv4" then .address = $v4 | .peers[0].allowed_ips = ["0.0.0.0/0"]
      elif $family == "ipv6" then .address = $v6 | .peers[0].allowed_ips = ["::/0"]
      elif $family == "dual" then .address = ($v4 + $v6) | .peers[0].allowed_ips = ["0.0.0.0/0", "::/0"]
      else error("无效的 WARP 地址族") end
    '
}

_warp_apply_family() (
    local family="$1" endpoint="$2" pool="$3" config state
    endpoint=$(_warp_endpoint_for_family "$family" "$pool" <<< "$endpoint") || exit 1
    config=$(mktemp "${CONFIG_FILE}.XXXXXX") || exit 1
    trap 'rm -f "$config" "${state:-}"' EXIT
    state=$(mktemp "${STATE_FILE}.XXXXXX") || exit 1
    jq --slurpfile ep /dev/fd/3 '
      .endpoints = ([.endpoints[]? | select(.tag != "warp-out")] + $ep) |
      .outbounds = [.outbounds[]? | select(.tag != "warp-out")]
    ' 3<<< "$endpoint" "$CONFIG_FILE" > "$config" &&
        jq --argjson pool "$pool" '.warp_address_pool = $pool' "$STATE_FILE" > "$state" &&
        sbx_apply_config_safe "$config" "$state"
)

_warp_change_family() (
    acquire_lock || exit 1
    local entry endpoint pool current
    entry=$(_warp_entry) || { printf '请先接入 WARP。\n'; exit 1; }
    endpoint=$(jq -ce '.endpoints[0] | select(.type == "wireguard" and (.peers | length) == 1)' <<< "$entry") || {
        printf '当前不是 SBX 支持的单对端 WireGuard 配置，请先重新接入。\n'; exit 1;
    }
    current=$(_warp_family <<< "$entry") || exit 1
    [[ "$current" != "$1" ]] || exit 0
    pool=$(jq -ce --slurpfile state "$STATE_FILE" '
      .address as $active | [$active[], ($state[0].warp_address_pool // [])[] as $saved |
        select(all($active[]; contains(":") != ($saved | contains(":")))) | $saved] | unique
    ' <<< "$endpoint") || exit 1
    _warp_apply_family "$1" "$endpoint" "$pool"
)

_show_warp_addresses() {
    local addresses
    addresses=$(_warp_entry | jq -r '(.endpoints[0].address // .outbounds[0].local_address // []) | if type == "array" then join(" · ") else . end')
    printf '  %b隧道地址（非公网 IP）:%b %s\n' "$CYAN" "$NC" "${addresses:-未配置}"
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

_sync_warp_rules() {
    jq --slurpfile state "$2" '
      ($state[0] | [.warp_nodes[]? as $t | select(.nodes[$t] != null) | $t]) as $nodes |
      ($state[0].warp_custom_domains // []) as $domains |
      .route.rules |= (
        map(select(.outbound != "warp-out" or (.inbound == null and .domain_suffix == null))) |
        (if ($nodes | length) > 0 and (any(.[]; .ip_is_private == true) | not) then
          [{action: "route", ip_is_private: true, outbound: "direct"}] + . else . end) +
        (if ($domains | length) > 0 then [{action: "route", domain_suffix: $domains, outbound: "warp-out"}] else [] end) +
        (if ($nodes | length) > 0 then [{action: "route", inbound: $nodes, outbound: "warp-out"}] else [] end)
      )
    ' "$1"
}

_warp_edit_state() (
    acquire_lock || exit 1
    local state config
    state=$(mktemp "${STATE_FILE}.XXXXXX") || exit 1
    trap 'rm -f "$state" "${config:-}"' EXIT
    config=$(mktemp "${CONFIG_FILE}.XXXXXX") || exit 1
    jq "$@" "$STATE_FILE" > "$state" &&
        _sync_warp_rules "$CONFIG_FILE" "$state" > "$config" &&
        sbx_apply_config_safe "$config" "$state"
)

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
        case "$wn_opt" in
            0|'') return 0 ;;
            a|A) _warp_edit_state '.warp_nodes = (.nodes | keys)' || pause_for_enter ;;
            c|C) _warp_edit_state '.warp_nodes = []' || pause_for_enter ;;
            *)
                if [[ "$wn_opt" =~ ^[1-9][0-9]*$ ]] && [ "$wn_opt" -le "${#tags[@]}" ]; then
                    _warp_edit_state --arg t "${tags[$((wn_opt - 1))]}" '
                      .warp_nodes |= ((. // []) | if index($t) != null then map(select(. != $t)) else . + [$t] end)
                    ' || pause_for_enter
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
    _show_warp_addresses
    print_divider
    printf "  1. %b指定节点分流:%b %s\n" "$BOLD" "$NC" "${w_nodes[*]:-无}"
    printf "  2. %bAI 智能分流 :%b %b\n" "$BOLD" "$NC" "$ai_st"
    printf "  3. %b流媒体分流  :%b %b\n" "$BOLD" "$NC" "$stream_st"
    printf "  4. %b自定义域名  :%b %s\n" "$BOLD" "$NC" "${c_doms[*]:-无}"
    print_divider
    pause_for_enter
}

_probe_warp() (
    umask 077
    local dir pid port attempt family version target result results=() families=()
    family=$(_warp_entry | _warp_family) || family=dual
    case "$family" in ipv4) families=(4) ;; ipv6) families=(6) ;; *) families=(4 6) ;; esac
    dir=$(mktemp -d /tmp/sbx_warp_probe_XXXXXX) || exit 1
    trap 'if [ -n "${pid:-}" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi; rm -rf "$dir"' EXIT
    trap 'exit 1' HUP INT TERM
    _warp_entry | jq -e '. + {
      log: {level: "info"},
      inbounds: [{type: "mixed", tag: "warp-probe", listen: "127.0.0.1", listen_port: 0}],
      route: {final: "warp-out"}
    }' > "$dir/config.json" || exit 1
    "$BIN_FILE" --disable-color run -c "$dir/config.json" > "$dir/log" 2>&1 &
    pid=$!
    for ((attempt=0; attempt<30; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        port=$(sed -nE 's/^.*inbound\/mixed\[warp-probe\]: tcp server started at 127\.0\.0\.1:([0-9]+).*$/\1/p' "$dir/log")
        if [ -n "$port" ] && grep -q 'sing-box started' "$dir/log"; then break; fi
        sleep 0.1
    done
    if [ -z "$port" ] || ! kill -0 "$pid" 2>/dev/null || ! grep -q 'sing-box started' "$dir/log"; then
        printf '%b[!] WARP 测试进程启动失败，请检查核心版本与端点配置%b\n' "$RED" "$NC" >&2
        exit 1
    fi
    local verified=0
    for version in "${families[@]}"; do
        case "$version" in 4) target=1.1.1.1 ;; 6) target='[2606:4700:4700::1111]' ;; esac
        if result=$(_warp_trace "$port" "$version" "$target"); then
            verified=1
            results+=("IPv$version $result")
        else
            results+=("IPv$version 未确认")
        fi
    done
    if [ "$verified" -eq 0 ]; then
        printf '%b[!] Trace 未确认流量经过 WARP: %s%b\n' "$RED" "${results[*]}" "$NC" >&2
        exit 1
    fi
    printf '%s\n' "${results[*]}"
)

_warp_trace() {
    local trace ip colo flag
    # Force the destination family; curl -4/-6 alone only selects the SOCKS connection family.
    trace=$(curl -qfsS --noproxy '' --proxy "socks5h://127.0.0.1:$1" --connect-timeout 5 --max-time 10 \
      --connect-to "one.one.one.one:443:$3:443" https://one.one.one.one/cdn-cgi/trace 2>/dev/null) || return 1
    ip=$(awk -F= '/^ip=/{print $2; exit}' <<< "$trace")
    colo=$(awk -F= '/^colo=/{print $2; exit}' <<< "$trace")
    flag=$(awk -F= '/^warp=/{print $2; exit}' <<< "$trace")
    [[ "$colo" =~ ^[A-Z]{3}$ && "$flag" =~ ^(on|plus)$ ]] || return 1
    case "$2" in
        4) [[ "$ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1 ;;
        6) [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ && "$ip" == *:* ]] || return 1 ;;
    esac
    printf '%s (%s, warp=%s)' "$ip" "$colo" "$flag"
}

_test_warp_connectivity() {
    _show_warp_addresses
    warp_exit_ip=""
    _has_warp_outbound || { printf '%b[!] 请先接入 WARP%b\n' "$YELLOW" "$NC"; return 1; }
    printf '%b>>> 正在检测 WARP 公网出口…%b\n' "$CYAN" "$NC"
    warp_exit_ip=$(_probe_warp) || return 1
    printf '  %b公网出口 IP:%b %s\n' "$GREEN" "$NC" "$warp_exit_ip"
}

_register_warp() (
    set +x
    umask 077
    local dir endpoint family pool
    family=$(_warp_entry | _warp_family) || family=""
    dir=$(mktemp -d) || exit 1
    trap 'rm -rf -- "$dir"' EXIT
    trap 'exit 1' HUP INT TERM
    _zero_trust_enroll "$dir/endpoint.json" || exit 1
    endpoint=$(cat "$dir/endpoint.json") || exit 1
    pool=$(jq -ce .address <<< "$endpoint") || exit 1
    if [ -z "$family" ]; then
        family=$(jq -c '{endpoints:[.]}' <<< "$endpoint" | _warp_family) || exit 1
    fi
    confirm_action "应用 Zero Trust 端点并重启 SBX？保留当前分流及默认出口。" || exit 1
    install_singbox_bin && deploy_sbx_service || exit 1
    _warp_apply_family "$family" "$endpoint" "$pool"
)

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
    local warp_exit_ip=""
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
        if _has_warp_outbound; then
            _show_warp_addresses
            printf '  WARP 出口地址族: %s\n' "$(_warp_family_label "$(_warp_entry | _warp_family)")"
            printf '  %b公网出口 IP:%b %s\n' "$CYAN" "$NC" "${warp_exit_ip:-未检测，选 3 查询}"
        fi
        printf "  %b分流:%b 节点[%b%s%b] · AI[%b] · 流媒体[%b] · 域名[%b%s%b]\n\n" \
            "$CYAN" "$NC" "$YELLOW" "$node_cnt" "$NC" "$ai_tag" "$stream_tag" "$CYAN" "$dom_cnt" "$NC"

        menu_pair 1 "Zero Trust 登录/重置" 2 "查看规则详情"
        menu_pair 3 "查询 WARP 公网 IP" 4 "全局 WARP 开关"
        print_divider
        menu_pair 5 "指定节点走 WARP" 6 "AI 分流开关"
        menu_pair 7 "流媒体分流开关" 8 "添加分流域名"
        menu_pair 9 "删除分流域名" 10 "彻底移除 WARP"
        menu_single 11 "WARP 出口地址族"
        menu_single 0 "返回"

        _read_menu_choice warp_opt "> 选择 [0-11]: "
        case "$warp_opt" in
            1)
                confirm_action "通过邮箱验证码注册 Zero Trust 设备？将下载并校验固定版本登录组件。" || continue
                acquire_lock || continue
                if _register_warp; then
                    printf '\n%b[OK] WARP 端点已就绪%b\n' "$GREEN" "$NC"
                    _test_warp_connectivity
                fi
                pause_for_enter ;;
            2) _show_warp_rules_detail ;;
            3) _test_warp_connectivity; pause_for_enter ;;
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
                local raw_doms new_doms=() parts=() d json_arr
                read -rp "  输入分流域名 (空格分隔, 如 claude.ai reddit.com): " raw_doms
                raw_doms=$(echo "$raw_doms" | tr -d '\r')
                [ -n "$raw_doms" ] || continue
                read -r -a parts <<< "$raw_doms"
                for d in "${parts[@]}"; do
                    d=$(echo "$d" | tr '[:upper:]' '[:lower:]' | sed -E 's|^https?://||; s|/.*$||')
                    [[ "$d" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && new_doms+=("$d")
                done
                [ "${#new_doms[@]}" -gt 0 ] || { printf '%b[!] 域名格式无效%b\n' "$RED" "$NC"; pause_for_enter; continue; }
                json_arr=$(printf '%s\n' "${new_doms[@]}" | jq -Rn '[inputs]')
                _warp_edit_state --argjson new "$json_arr" '.warp_custom_domains |= ((. // []) + $new | unique)' &&
                    printf '%b[OK] 已添加: %s%b\n' "$GREEN" "${new_doms[*]}" "$NC"
                pause_for_enter ;;
            9)
                local cur_doms=() d idx=1 del_choice
                while IFS= read -r d; do [ -n "$d" ] && cur_doms+=("$d"); done < <(_get_warp_custom_domains)
                [ "${#cur_doms[@]}" -gt 0 ] || { printf '\n%b[!] 暂无自定义域名%b\n' "$YELLOW" "$NC"; pause_for_enter; continue; }
                printf '\n'
                for d in "${cur_doms[@]}"; do printf "  %b%2d.%b %s\n" "$CYAN" "$idx" "$NC" "$d"; idx=$((idx + 1)); done
                read -rp "  输入编号删除 (a 清空全部, 0 返回): " del_choice; del_choice="${del_choice// /}"
                case "$del_choice" in
                    0|'') continue ;;
                    a|A)
                        confirm_action "清空所有自定义分流域名？" || continue
                        _warp_edit_state '.warp_custom_domains = []' && printf '%b[OK] 已清空%b\n' "$GREEN" "$NC"
                        pause_for_enter ;;
                    *)
                        if [[ "$del_choice" =~ ^[1-9][0-9]*$ ]] && [ "$del_choice" -le "${#cur_doms[@]}" ]; then
                            local target_dom="${cur_doms[$((del_choice - 1))]}"
                            _warp_edit_state --arg d "$target_dom" '.warp_custom_domains |= map(select(. != $d))' &&
                                printf '%b[OK] 已删除: %s%b\n' "$GREEN" "$target_dom" "$NC"
                            pause_for_enter
                        fi ;;
                esac ;;
            10)
                confirm_action "彻底移除 WARP 出口及全部关联规则？" || continue
                acquire_lock || continue
                local tmp_c tmp_s
                tmp_c=$(mktemp "${CONFIG_FILE}.XXXXXX") || continue
                tmp_s=$(mktemp "${STATE_FILE}.XXXXXX") || { rm -f "$tmp_c"; continue; }
                jq '
                  .endpoints = [.endpoints[]? | select(.tag != "warp-out")] |
                  .outbounds = [.outbounds[]? | select(.tag != "warp-out")] |
                  .route.final |= (if . == "warp-out" then "direct" else . end) |
                  .route.rule_set = [.route.rule_set[]? | select(.tag != "geosite-ai" and .tag != "geosite-stream")] |
                  .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]
                ' "$CONFIG_FILE" > "$tmp_c" &&
                jq '.warp_custom_domains = [] | .warp_nodes = [] | del(.warp_address_pool)' "$STATE_FILE" > "$tmp_s" &&
                sbx_apply_config_safe "$tmp_c" "$tmp_s" && {
                    warp_exit_ip=""
                    printf '\n%b[OK] WARP 及分流规则已移除%b\n' "$GREEN" "$NC"
                }
                rm -f "$tmp_c" "$tmp_s"
                pause_for_enter ;;
            11)
                local family choice
                _read_menu_choice choice '出口地址族 [1 仅 IPv4 / 2 仅 IPv6 / 3 双栈 / 0 返回]: '
                case "$choice" in
                    1) family=ipv4 ;; 2) family=ipv6 ;; 3) family=dual ;; *) continue ;;
                esac
                printf '仅影响走 WARP 的流量，不改服务器接入地址。单栈不兼容另一地址族。\n'
                confirm_action "切换到 $(_warp_family_label "$family")？如有变更会重启 sbx" || continue
                _warp_change_family "$family" && _test_warp_connectivity
                pause_for_enter ;;
            0) return 0 ;;
        esac
    done
}
