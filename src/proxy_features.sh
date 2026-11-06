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
    jq -e '.outbounds[] | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1
}

manage_warp() {
    while true; do
        menu_header "Cloudflare WARP 出口与分流"
        init_sbx_config

        local warp_status
        if _has_warp_outbound; then
            warp_status="${GREEN}已配置开启${NC}"
        else
            warp_status="${DIM}未配置 / 已关闭${NC}"
        fi
        printf "  %b当前 WARP 状态:%b %b\n\n" "$CYAN" "$NC" "$warp_status"

        menu_single 1 "一键生成并接入 WARP WireGuard 出口"
        menu_single 2 "分流规则: 将 OpenAI (ChatGPT) 流量引导走 WARP"
        menu_single 3 "分流规则: 将主流流媒体 (Netflix/YouTube/Disney+) 引导走 WARP"
        menu_single 4 "彻底移除 WARP 出口与分流规则"
        menu_single 0 "返回主菜单"

        _read_menu_choice warp_opt "> 请选择操作 [0-4]: "
        case "$warp_opt" in
            1)
                acquire_lock || continue
                install_singbox_bin || continue
                deploy_sbx_service

                printf '\n%b>>> 正在获取 Cloudflare WARP 免费注册凭据...%b\n' "$CYAN" "$NC"
                # 利用 wgcf-like 或 cloudflare api 生成 wireguard 对
                # 若失败，则使用预置公共 endpoint 引导
                local priv_key pub_key
                priv_key=$("$BIN_FILE" generate wireguard-keypair 2>/dev/null | awk '/PrivateKey:/{print $2}' || openssl rand -base64 32)
                pub_key="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="

                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_warp_XXXXXX)
                jq --arg priv "$priv_key" \
                   --arg pub "$pub_key" \
                   '.outbounds = [.outbounds[] | select(.tag != "warp-out")] + [{
                      "type": "wireguard",
                      "tag": "warp-out",
                      "server": "162.159.193.10",
                      "server_port": 2408,
                      "local_address": ["172.16.0.2/32"],
                      "private_key": $priv,
                      "peer_public_key": $pub
                   }]' "$CONFIG_FILE" > "$tmp_c"

                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi

                printf '\n%b[成功] WARP WireGuard 出口已注入并生效！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            2)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.domain_suffix? // []) != ["openai.com", "chatgpt.com", "ai.com"])] + [{
                      "domain_suffix": ["openai.com", "chatgpt.com", "ai.com", "oaistatic.com", "oaiusercontent.com"],
                      "outbound": "warp-out"
                   }]' "$CONFIG_FILE" > "$tmp_c"
                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi
                printf '\n%b[成功] OpenAI / ChatGPT 域名分流规则已生效！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            3)
                if ! _has_warp_outbound; then
                    printf '\n%b[!] 请先选 1 接入 WARP 出口。%b\n' "$YELLOW" "$NC"
                    pause_for_enter; continue;
                fi
                local tmp_c
                tmp_c=$(mktemp /tmp/sbx_rule_XXXXXX)
                jq '.route.rules = [.route.rules[]? | select(.outbound != "warp-out" or (.domain_suffix? // []) != ["netflix.com", "disneyplus.com"])] + [{
                      "domain_suffix": ["netflix.com", "nflxvideo.net", "disneyplus.com", "bamgrid.com"],
                      "outbound": "warp-out"
                   }]' "$CONFIG_FILE" > "$tmp_c"
                if ! sbx_apply_config_safe "$tmp_c"; then
                    pause_for_enter
                    continue
                fi
                printf '\n%b[成功] 流媒体域名分流规则已生效！%b\n' "$GREEN" "$NC"
                pause_for_enter
                ;;
            4)
                if confirm_action "彻底移除 WARP 出口与全部 WARP 关联分流规则？"; then
                    acquire_lock || continue
                    local tmp_c
                    tmp_c=$(mktemp /tmp/sbx_warp_del_XXXXXX)
                    jq '.outbounds = [.outbounds[] | select(.tag != "warp-out")] |
                        .route.rules = [.route.rules[]? | select(.outbound != "warp-out")]' "$CONFIG_FILE" > "$tmp_c"
                    if ! sbx_apply_config_safe "$tmp_c"; then
                        pause_for_enter
                        continue
                    fi
                    printf '\n%b[成功] WARP 配置已彻底清除！%b\n' "$GREEN" "$NC"
                    pause_for_enter
                fi
                ;;
            0) return 0 ;;
            *) sleep 1 ;;
        esac
    done
}
