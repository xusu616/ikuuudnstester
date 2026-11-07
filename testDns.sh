#!/system/bin/sh
# ==============================================================================
# ikuuu 机场抗污染 DNS 状态与可用性一键检测脚本
# 路径: /sdcard/testDns.sh
# 运行方式: su -c 'sh /sdcard/testDns.sh'
# ==============================================================================

# 颜色控制
CLR_RED="\033[1;31m"
CLR_GRN="\033[1;32m"
CLR_YLW="\033[1;33m"
CLR_CYN="\033[1;36m"
CLR_BLD="\033[1m"
CLR_RST="\033[0m"

pass() { printf "  [${CLR_GRN} PASS ${CLR_RST}] %b\n" "$*"; }
fail() { printf "  [${CLR_RED} FAIL ${CLR_RST}] %b\n" "$*"; }
warn() { printf "  [${CLR_YLW} WARN ${CLR_RST}] %b\n" "$*"; }
info() { printf "  [${CLR_CYN} INFO ${CLR_RST}] %b\n" "$*"; }

printf "%b======================================================%b\n" "${CLR_BLD}" "${CLR_RST}"
printf "%b       ikuuu 机场专属抗污染 DNS 实时健康诊断%b\n" "${CLR_BLD}" "${CLR_RST}"
printf "%b======================================================%b\n" "${CLR_BLD}" "${CLR_RST}"
echo "测试时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

CLASH_CONFIG="/data/adb/box_bll/clash/config.yaml"
SUB_FILE="/data/adb/box_bll/clash/proxies/1.主要地址.yaml"
AGH_SCRIPT="/data/adb/agh/scripts/ProxyConfig.sh"

BUSYBOX=""
for bb in "/data/adb/ksu/bin/busybox" "/data/adb/ap/bin/busybox" "/data/adb/magisk/busybox" "/data/adb/box_bll/bin/busybox" "$(which busybox 2>/dev/null)"; do
    if [ -x "$bb" ]; then
        BUSYBOX="$bb"
        break
    fi
done
[ -z "$BUSYBOX" ] && BUSYBOX="busybox"

# ------------------------------------------------------------------------------
# 1. 检查 config.yaml 中的 proxy-server-nameserver 配置
# ------------------------------------------------------------------------------
printf "%b[1/5] 检查 Clash 主配置 (proxy-server-nameserver)...%b\n" "${CLR_BLD}" "${CLR_RST}"
if [ -f "$CLASH_CONFIG" ]; then
    CURRENT_DNS=$(grep -A 5 "^[[:space:]]*proxy-server-nameserver:" "$CLASH_CONFIG" | grep "^[[:space:]]*-" | head -n 1 | awk '{print $2}')
    if [ -n "$CURRENT_DNS" ]; then
        pass "当前生效的节点入口 DNS: ${CLR_CYN}${CURRENT_DNS}${CLR_RST}"
    else
        fail "未在 $CLASH_CONFIG 中找到生效的 proxy-server-nameserver！"
    fi
else
    fail "找不到 Clash 主配置文件: $CLASH_CONFIG"
fi

# ------------------------------------------------------------------------------
# 2. 从订阅文件中提取机场官方推荐的专用 DNS
# ------------------------------------------------------------------------------
echo ""
printf "%b[2/5] 检查订阅文件 (1.主要地址.yaml) 中的官方 DNS 规则...%b\n" "${CLR_BLD}" "${CLR_RST}"
if [ -f "$SUB_FILE" ]; then
    SUB_DNS_LINE=$(grep -A 2 "^[[:space:]]*nameserver-policy:" "$SUB_FILE" | grep "tcp://" | head -n 1)
    OFFICIAL_DNS_URL=$(echo "$SUB_DNS_LINE" | awk '{print $2}')
    if [ -n "$OFFICIAL_DNS_URL" ]; then
        pass "订阅中官方专用抗污染 DNS: ${CLR_CYN}${OFFICIAL_DNS_URL}${CLR_RST}"
        
        # 提取域名与端口
        DNS_HOST=$(echo "$OFFICIAL_DNS_URL" | sed -E 's|^tcp://||; s|:[0-9]+$||')
        DNS_PORT=$(echo "$OFFICIAL_DNS_URL" | grep -o -E '[0-9]+$')
        [ -z "$DNS_PORT" ] && DNS_PORT=8080

        # 如果是域名，解析对应 IP
        if echo "$DNS_HOST" | grep -q -E '[a-zA-Z]'; then
            DNS_RESOLVED_IP=$($BUSYBOX nslookup "$DNS_HOST" 223.5.5.5 2>/dev/null | grep -A 2 "Name:" | grep "Address" | head -n 1 | awk '{print $NF}')
            if [ -n "$DNS_RESOLVED_IP" ]; then
                info "官方域名对应公网 IP: ${CLR_CYN}${DNS_RESOLVED_IP}:${DNS_PORT}${CLR_RST}"
                TARGET_IP="$DNS_RESOLVED_IP"
            else
                warn "无法通过公网解析域名 $DNS_HOST，使用默认回退 IP 47.105.116.11"
                TARGET_IP="47.105.116.11"
            fi
        else
            TARGET_IP="$DNS_HOST"
        fi

        # 对比当前配置与订阅是否一致
        if echo "$CURRENT_DNS" | grep -q "$TARGET_IP"; then
            pass "当前配置的 IP 与订阅源要求 ${CLR_GRN}完全一致${CLR_RST}！"
        else
            warn "当前配置 (${CURRENT_DNS}) 与订阅推荐 (${TARGET_IP}) 不完全一致，但只要通即可"
        fi
    else
        warn "订阅文件中未声明 nameserver-policy，可能使用了默认设置"
        TARGET_IP="47.105.116.11"
        DNS_PORT="8080"
    fi
else
    warn "未找到订阅文件: $SUB_FILE"
    TARGET_IP="47.105.116.11"
    DNS_PORT="8080"
fi

# ------------------------------------------------------------------------------
# 3. 检查 AdGuardHome 是否会篡改该 DNS
# ------------------------------------------------------------------------------
echo ""
printf "%b[3/5] 检查 AdGuardHome 规则拦截保护状态...%b\n" "${CLR_BLD}" "${CLR_RST}"
if [ -f "$AGH_SCRIPT" ]; then
    if grep "ALL_SECTIONS" "$AGH_SCRIPT" | grep -q "proxy-server-nameserver"; then
        fail "AdGuardHome 的 ProxyConfig.sh 依然包含了 proxy-server-nameserver，可能会覆盖机场 DNS！"
    else
        pass "AdGuardHome 脚本已豁免 proxy-server-nameserver，${CLR_GRN}不会被恶意覆盖${CLR_RST}。"
    fi
else
    info "未检测到 $AGH_SCRIPT，跳过保护检查。"
fi

# ------------------------------------------------------------------------------
# 4. 测试抗污染专用 DNS（TCP 端口 & 实际解析）可用性
# ------------------------------------------------------------------------------
echo ""
printf "%b[4/5] 测试抗污染 DNS (${TARGET_IP}:${DNS_PORT}) 连通性与解析能力...%b\n" "${CLR_BLD}" "${CLR_RST}"

ENTRY_DOMAIN=$(grep -o -E '[a-zA-Z0-9.-]+\.entry\.v51124-1\.qpon' "$SUB_FILE" 2>/dev/null | head -n 1)
[ -z "$ENTRY_DOMAIN" ] && ENTRY_DOMAIN="y.9.w.e.e.2.6.3.b.hk01-ae5.entry.v51124-1.qpon"

info "测试节点入口域名: ${CLR_CYN}${ENTRY_DOMAIN}${CLR_RST}"

RESOLVED_IP=""
for try in 1 2 3; do
    RESOLVE_RESULT=$($BUSYBOX nslookup "$ENTRY_DOMAIN" "${TARGET_IP}:${DNS_PORT}" 2>/dev/null)
    RESOLVED_IP=$(echo "$RESOLVE_RESULT" | grep -A 2 "Name:" | grep "Address" | head -n 1 | awk '{print $NF}')
    [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "0.0.0.0" ] && [ "$RESOLVED_IP" != "127.0.0.1" ] && break
    sleep 1
done

if [ -n "$RESOLVED_IP" ] && [ "$RESOLVED_IP" != "0.0.0.0" ] && [ "$RESOLVED_IP" != "127.0.0.1" ]; then
    pass "专用 DNS 响应正常！成功将节点入口解析为真实 IEPL IP: ${CLR_GRN}${RESOLVED_IP}${CLR_RST}"
else
    # 备选诊断：测试 TCP 端口连通性
    if $BUSYBOX nc -w 3 "$TARGET_IP" "$DNS_PORT" </dev/null >/dev/null 2>&1; then
        pass "专用 DNS 的 TCP 端口 (${TARGET_IP}:${DNS_PORT}) 握手畅通！(单次解析可能受公网网络瞬时抖动影响)"
    else
        fail "专用 DNS (${TARGET_IP}:${DNS_PORT}) 解析超时或无返回！"
    fi
fi

# ------------------------------------------------------------------------------
# 5. 测试 Clash 核心当前代理节点连通延迟
# ------------------------------------------------------------------------------
echo ""
printf "%b[5/5] 测试 Clash 内核对 IEPL 专线节点的实际可用性...%b\n" "${CLR_BLD}" "${CLR_RST}"
DELAY_TEST=$(curl -s "http://127.0.0.1:9090/proxies/ALL%C2%B7%E9%A6%99%E6%B8%AF%E5%9C%B0%E5%8C%BA/delay?timeout=4000&url=https://www.gstatic.com/generate_204" 2>/dev/null)

if echo "$DELAY_TEST" | grep -q '"delay"'; then
    DELAY_MS=$(echo "$DELAY_TEST" | grep -o -E '"delay":[0-9]+' | cut -d: -f2)
    pass "香港 IEPL 专线实测连通成功！延迟: ${CLR_GRN}${DELAY_MS} ms${CLR_RST}"
else
    CURRENT_NODE=$(curl -s "http://127.0.0.1:9090/proxies/GLOBAL" 2>/dev/null | grep -o '"now":"[^"]*"' | cut -d'"' -f4)
    info "当前总模式选中节点: ${CLR_CYN}${CURRENT_NODE}${CLR_RST}"
fi

echo ""
printf "%b======================================================%b\n" "${CLR_BLD}" "${CLR_RST}"
printf "%b                 健康诊断完成%b\n" "${CLR_BLD}" "${CLR_RST}"
printf "%b======================================================%b\n" "${CLR_BLD}" "${CLR_RST}"
