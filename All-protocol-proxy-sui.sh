#!/bin/bash
# ===================================================================
# All-protocol-proxy-sui.sh
# 一键全协议部署 + S-UI 面板管理合并版
# 功能: 4K内核调优 + S-UI面板(接管sing-box) + Cloudflare Argo隧道 + 路由器分流
#       + Snell/SS/VLESS/Trojan 节点 + 优选域名 cf.877774.xyz
# 本版修复: S-UI 安装报 404 (vinstall)。alireza0/s-ui 的 install.sh 第一个位置
#           参数是「版本号」而不是子命令, 之前误传 "install" 被当成版本号,
#           于是去请求不存在的 vinstall 资产 -> 404。
# ===================================================================

set -e

# ========================= 默认配置 =========================
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"
TUNNEL_HOSTNAME="${TUNNEL_HOSTNAME:-}"
TUNNEL_LOCAL_PORT="${TUNNEL_LOCAL_PORT:-}"

PANEL_PORT="${PANEL_PORT:-2095}"
PANEL_PATH="${PANEL_PATH:-/app/}"
SUB_PORT="${SUB_PORT:-2096}"
SUB_PATH="${SUB_PATH:-/sub/}"
PANEL_USER="${PANEL_USER:-}"
PANEL_PASS="${PANEL_PASS:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
SUI_VERSION="${SUI_VERSION:-}"

INSTALL_DIR="/opt/All-protocol-proxy"
SUI_DIR="/usr/local/s-ui"
SUI_DB_DIR="$SUI_DIR/db"
SUI_CONFIG_DIR="$SUI_DIR/config"
SUB_PORT_FILE="/etc/suoha_sub_port"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-linux"
ARGO_ROUTER_BIN="/usr/local/bin/argo_router"

# 优选域名（全部统一为 cf.877774.xyz）
opt_domains=("cf.877774.xyz")
opt_labels=("优选cf.877774")

# ========================= 颜色与日志 =========================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}==== $1 ====${NC}"; }

progress() {
    local percent=$1
    local msg=$2
    local filled=$((percent / 5))
    local empty=$((20 - filled))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="="; done
    for ((i=0; i<empty; i++)); do bar+="."; done
    echo -e "[${bar}] ${percent}% - ${msg}"
}

# ========================= 参数解析 =========================
UNINSTALL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        uninstall) UNINSTALL=1; shift ;;
        --tunnel-token) TUNNEL_TOKEN="$2"; shift 2 ;;
        --tunnel-hostname) TUNNEL_HOSTNAME="$2"; shift 2 ;;
        --tunnel-local-port) TUNNEL_LOCAL_PORT="$2"; shift 2 ;;
        --panel-port) PANEL_PORT="$2"; shift 2 ;;
        --panel-path) PANEL_PATH="$2"; shift 2 ;;
        --panel-sub-port) SUB_PORT="$2"; shift 2 ;;
        --panel-sub-path) SUB_PATH="$2"; shift 2 ;;
        --panel-user) PANEL_USER="$2"; shift 2 ;;
        --panel-pass) PANEL_PASS="$2"; shift 2 ;;
        --panel-domain) PANEL_DOMAIN="$2"; shift 2 ;;
        --sui-version) SUI_VERSION="$2"; shift 2 ;;
        *) log_error "未知参数: $1"; exit 1 ;;
    esac
done

# ========================= 卸载 =========================
do_uninstall() {
    log_step "开始卸载"
    [ -x "$SUI_DIR/s-ui" ] && "$SUI_DIR/s-ui" stop 2>/dev/null || true
    systemctl disable --now s-ui 2>/dev/null || true
    systemctl disable --now sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/s-ui.service /etc/systemd/system/sing-box.service
    pkill -f sing-box 2>/dev/null || true
    pkill -f cloudflared 2>/dev/null || true
    pkill -f argo_router 2>/dev/null || true

    rm -rf "$SUI_DIR" "$INSTALL_DIR" /var/www/suoha_sub
    rm -f /etc/suoha_sub_port /etc/sysctl.d/99-suoha-4k.conf
    rm -f "$CLOUDFLARED_BIN" "$ARGO_ROUTER_BIN" /usr/local/bin/s-ui
    rm -f /tmp/sui_nodes_info /tmp/argo_*.log /tmp/sui-install.sh

    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload
    log_info "卸载完成"
}

if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
    exit 0
fi

# ========================= 环境检查 =========================
check_env() {
    log_step "环境检查"
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用 root 权限运行 (sudo bash $0)"
        exit 1
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "系统: ${ID:-未知} ${VERSION_ID:-}"
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        arm64)   ARCH="arm64" ;;
        armv7l)  ARCH="arm" ;;
        *) log_error "不支持的架构: $arch"; exit 1 ;;
    esac
    log_info "系统架构: $ARCH"

    if ! command -v curl &>/dev/null; then
        log_info "安装 curl..."
        if command -v apt-get &>/dev/null; then apt-get update -y && apt-get install -y curl
        elif command -v yum &>/dev/null; then yum install -y curl
        elif command -v apk &>/dev/null; then apk add --no-cache curl
        else log_error "无法安装 curl"; exit 1; fi
    fi
    mkdir -p "$INSTALL_DIR"
}

# ========================= 4K 内核调优 =========================
tune_kernel() {
    log_step "4K 内核调优 (BBR + 拥塞控制)"
    cat > /etc/sysctl.d/99-suoha-4k.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 1000000
EOF
    sysctl --system >/dev/null 2>&1 || true
    log_info "内核参数已应用"
}

# ========================= 安装组件 =========================
install_cloudflared() {
    log_step "安装 cloudflared"
    if [ -f "$CLOUDFLARED_BIN" ] && [ -x "$CLOUDFLARED_BIN" ]; then
        log_info "cloudflared 已存在, 跳过下载"
        return
    fi
    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    log_info "下载 cloudflared..."
    curl -fsSL -o "$CLOUDFLARED_BIN" "$url"
    chmod +x "$CLOUDFLARED_BIN"
    log_info "cloudflared 安装完成"
}

install_argo_router() {
    log_step "安装 argo_router (分流路由器, 可选组件)"
    if [ -f "$ARGO_ROUTER_BIN" ] && [ -x "$ARGO_ROUTER_BIN" ]; then
        log_info "argo_router 已存在, 跳过下载"
        return
    fi
    # 依次尝试多个候选资产名, 全部失败则降级为单隧道模式(不分流), 不影响主流程
    local base="https://github.com/fscarmen/argo-go/releases/latest/download"
    local ok=0 cand
    for cand in "argo-go-linux-${ARCH}" "argo-go-linux-arm64" "argo-router-linux-${ARCH}"; do
        if curl -fsSL -o "$ARGO_ROUTER_BIN" "${base}/${cand}" 2>/dev/null; then
            chmod +x "$ARGO_ROUTER_BIN"
            log_info "argo_router 安装完成 ($cand)"
            ok=1
            break
        fi
    done
    if [ "$ok" -ne 1 ]; then
        rm -f "$ARGO_ROUTER_BIN"
        log_warn "argo_router 下载失败, 将使用单隧道模式(不分流)"
        ARGO_ROUTER_BIN=""
    fi
}

# ---------- S-UI 安装（本版修复 404 的关键函数）----------
# alireza0/s-ui 安装器用法:  bash install.sh [version]
#   位置参数 = 版本号(如 1.9.0 或 v1.9.0); 省略时安装器自行取 GitHub 最新 release。
#   传 "install" 会被当成版本号 -> 请求 vinstall 的 release 资产 -> 404。
resolve_latest_sui_version() {
    local tag
    tag=$(curl -fsSL --max-time 15 \
        https://api.github.com/repos/alireza0/s-ui/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d '"' -f4) || true
    [ -n "$tag" ] && echo "${tag#v}"
}

install_sui() {
    log_step "安装 S-UI 面板"
    if [ -f "$SUI_DIR/s-ui" ]; then
        log_warn "S-UI 已安装, 跳过安装步骤"
        return
    fi

    log_info "下载 S-UI 安装器..."
    curl -fsSL -o /tmp/sui-install.sh \
        https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh

    # 版本号优先级: 命令行参数 --sui-version > GitHub API 解析 > 安装器自行探测
    if [ -z "$SUI_VERSION" ]; then
        SUI_VERSION=$(resolve_latest_sui_version || true)
    fi

    if [ -n "$SUI_VERSION" ]; then
        log_info "安装 S-UI 版本: ${SUI_VERSION}"
        bash /tmp/sui-install.sh "${SUI_VERSION}" || {
            log_warn "指定版本 ${SUI_VERSION} 安装失败, 改用自动探测模式重试..."
            bash /tmp/sui-install.sh
        }
    else
        log_warn "未解析到最新版本号(GitHub API 不可达), 交由安装器自动探测..."
        bash /tmp/sui-install.sh
    fi

    if [ ! -f "$SUI_DIR/s-ui" ]; then
        log_error "S-UI 安装失败。常见原因与处置:"
        log_error "  1) 机器访问 GitHub API / Releases 受限 -> 用 --sui-version 1.9.0 指定确切版本"
        log_error "  2) 该版本无 arm64 资产 -> 到项目 Releases 页确认资产名后换版本号重试"
        log_error "  3) 之前装过一半 -> 先执行 sudo bash $0 uninstall 再重装"
        exit 1
    fi
    ln -sf "$SUI_DIR/s-ui" /usr/local/bin/s-ui 2>/dev/null || true
    log_info "S-UI 安装完成"
}

# ========================= 工具函数 =========================
random_str() { cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
get_public_ip() {
    curl -sf --max-time 5 https://api.ipify.org || \
    curl -sf --max-time 5 https://ifconfig.me || \
    curl -sf --max-time 5 https://ipinfo.io/ip || echo "127.0.0.1"
}
get_idc_name() {
    local org
    org=$(curl -sf --max-time 5 "http://ip-api.com/json/$1?fields=org" 2>/dev/null | sed 's/.*"org":"\([^"]*\)".*/\1/') || org=""
    [ -z "$org" ] && org="VPS"
    echo "$org" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]' | head -c 12
}

# ========================= 配置 S-UI 与节点 =========================
configure_sui_and_nodes() {
    log_step "配置 S-UI 面板与全协议节点"

    [ -z "$PANEL_USER" ] && PANEL_USER="admin_$(random_str 6)"
    [ -z "$PANEL_PASS" ] && PANEL_PASS="$(random_str 16)"

    # 生成节点参数
    local ss_port=$((30000 + RANDOM % 10000))
    local ss_method="2022-blake3-aes-128-gcm"
    local ss_pass
    if command -v sing-box &>/dev/null; then
        ss_pass=$(sing-box generate rand --base64 16 2>/dev/null || random_str 16)
    else
        ss_pass=$(random_str 16)
    fi

    local snell_port=$((30000 + RANDOM % 10000))
    local snell_psk=$(random_str 32)

    local vless_port=$((30000 + RANDOM % 10000))
    local vless_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || random_str 36)

    local trojan_port=$((30000 + RANDOM % 10000))
    local trojan_pass=$(random_str 16)

    local username="user_$(random_str 6)"

    # 写入 sing-box 配置文件, 由 S-UI 统一管理内核
    mkdir -p "$SUI_CONFIG_DIR"
    cat > "$SUI_CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks", "tag": "SS-直连", "listen": "::", "port": $ss_port,
      "method": "$ss_method", "password": "$ss_pass", "network": "tcp,udp"
    },
    {
      "type": "snell", "tag": "Snell-直连", "listen": "::", "port": $snell_port,
      "psk": "$snell_psk", "version": 3, "network": "tcp"
    },
    {
      "type": "vless", "tag": "VLESS-Argo", "listen": "::", "port": $vless_port,
      "uuid": "$vless_uuid", "network": "tcp,udp"
    },
    {
      "type": "trojan", "tag": "Trojan-Argo", "listen": "::", "port": $trojan_port,
      "password": "$trojan_pass", "network": "tcp,udp"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    # 配置面板参数并重启
    "$SUI_DIR/s-ui" setting -port "$PANEL_PORT" >/dev/null 2>&1 || true
    "$SUI_DIR/s-ui" setting -webBasePath "$PANEL_PATH" >/dev/null 2>&1 || true
    "$SUI_DIR/s-ui" setting -subPort "$SUB_PORT" >/dev/null 2>&1 || true
    "$SUI_DIR/s-ui" setting -subBasePath "$SUB_PATH" >/dev/null 2>&1 || true
    echo "$SUB_PORT" > "$SUB_PORT_FILE"

    "$SUI_DIR/s-ui" restart >/dev/null 2>&1 || true
    sleep 3

    # 保存节点信息
    cat > /tmp/sui_nodes_info <<EOF
SS_PORT=$ss_port
SS_METHOD=$ss_method
SS_PASS=$ss_pass
SNELL_PORT=$snell_port
SNELL_PSK=$snell_psk
VLESS_PORT=$vless_port
VLESS_UUID=$vless_uuid
TROJAN_PORT=$trojan_port
TROJAN_PASS=$trojan_pass
USERNAME=$username
EOF
    log_info "S-UI 与节点配置完成"
}

# ========================= 启动 Argo 隧道 =========================
start_argo_tunnel() {
    log_step "启动 Cloudflare Argo 隧道"
    if [ ! -f /tmp/sui_nodes_info ]; then
        log_error "未找到节点信息, 请先完成节点创建"
        return 1
    fi
    source /tmp/sui_nodes_info

    local local_port="${TUNNEL_LOCAL_PORT:-$VLESS_PORT}"

    if [ -n "$TUNNEL_TOKEN" ]; then
        log_info "使用固定命名隧道模式 (Token 已提供)"
        if [ -z "$TUNNEL_HOSTNAME" ]; then
            log_error "固定隧道必须同时提供 --tunnel-hostname"
            exit 1
        fi

        echo ""
        echo "================ 固定命名隧道 · 控制台配置对照 ================"
        echo "请到 Cloudflare Zero Trust -> Networks -> Tunnels -> (你的隧道) -> Public Hostname 核对:"
        echo "  Hostname : $TUNNEL_HOSTNAME"
        echo "  Service  : http://localhost:${local_port}    <- 端口必须等于 TUNNEL_LOCAL_PORT(${local_port})"
        echo "二者不一致会导致隧道虽连上但访问 502 / 连不上。核对无误后脚本继续。"
        echo "================================================================"
        echo ""

        # 本机监听预检
        if command -v ss &>/dev/null; then
            if ! ss -tlnp 2>/dev/null | grep -q ":${local_port} "; then
                log_warn "本机 ${local_port} 端口未检测到监听, 隧道连上后可能 502"
            fi
        fi

        # 全局参数 --no-autoupdate 必须放在 tunnel 子命令之前
        nohup "$CLOUDFLARED_BIN" --no-autoupdate tunnel run --token "$TUNNEL_TOKEN" \
            > /tmp/argo_fixed.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"
        TUNNEL_URL="https://$TUNNEL_HOSTNAME"
        log_info "固定隧道已启动: $TUNNEL_URL"
    else
        log_info "使用临时隧道模式"
        nohup "$CLOUDFLARED_BIN" --no-autoupdate tunnel --url "http://127.0.0.1:${local_port}" \
            > /tmp/argo_tmp.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"

        local waited=0
        TUNNEL_URL=""
        while [ "$waited" -lt 30 ]; do
            TUNNEL_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo_tmp.log 2>/dev/null | head -1)
            [ -n "$TUNNEL_URL" ] && break
            sleep 1
            waited=$((waited + 1))
        done
        if [ -n "$TUNNEL_URL" ]; then
            log_info "临时隧道已启动: $TUNNEL_URL"
        else
            log_warn "临时隧道 URL 提取失败, 请查看 /tmp/argo_tmp.log"
            TUNNEL_URL=""
        fi
    fi
    echo "TUNNEL_URL=$TUNNEL_URL" >> /tmp/sui_nodes_info

    # 启动分流路由器
    if [ -n "$ARGO_ROUTER_BIN" ] && [ -x "$ARGO_ROUTER_BIN" ]; then
        log_info "启动 Argo 分流路由器..."
        cat > "$INSTALL_DIR/argo_router.json" <<EOF
{
  "listen": "127.0.0.1:8080",
  "routes": [
    { "match": "domain", "value": "*.google.com", "target": "http://127.0.0.1:$VLESS_PORT" },
    { "match": "domain", "value": "*.cloudflare.com", "target": "http://127.0.0.1:$TROJAN_PORT" },
    { "match": "default", "target": "http://127.0.0.1:$VLESS_PORT" }
  ]
}
EOF
        nohup "$ARGO_ROUTER_BIN" -config "$INSTALL_DIR/argo_router.json" > /tmp/argo_router.log 2>&1 &
        echo $! > "$INSTALL_DIR/argo_router.pid"
        log_info "分流路由器已启动 (监听 127.0.0.1:8080)"
    fi
}

# ========================= 生成订阅与最终输出 =========================
generate_and_print() {
    log_step "生成订阅与部署信息"
    source /tmp/sui_nodes_info

    local public_ip=$(get_public_ip)
    local idc_name=$(get_idc_name "$public_ip")
    local opt_domain="${opt_domains[0]}"
    local opt_label="${opt_labels[0]}"

    # 直连节点链接
    local ss_link="ss://$(echo -n "$SS_METHOD:$SS_PASS" | base64 -w0)@$public_ip:$SS_PORT?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dwww.baidu.com#$idc_name-SS-直连"
    local snell_link="snell://$SNELL_PSK@$public_ip:$SNELL_PORT?version=3#$idc_name-Snell-直连"
    local vless_link="vless://$VLESS_UUID@$public_ip:$VLESS_PORT?encryption=none&security=none&type=tcp#$idc_name-VLESS-直连"
    local trojan_link="trojan://$TROJAN_PASS@$public_ip:$TROJAN_PORT?type=tcp#$idc_name-Trojan-直连"

    # 隧道节点（优选域名 + 默认隧道域名）
    local tunnel_host=""
    if [ -n "$TUNNEL_URL" ]; then
        tunnel_host=$(echo "$TUNNEL_URL" | sed 's|https://||')
    fi
    if [ -n "$tunnel_host" ]; then
        vless_link+="\nvless://$VLESS_UUID@${opt_domain}:443?encryption=none&security=tls&type=ws&host=$tunnel_host&sni=$tunnel_host&path=/#$idc_name-VLESS-${opt_label}-443"
        trojan_link+="\ntrojan://$TROJAN_PASS@${opt_domain}:443?security=tls&type=ws&host=$tunnel_host&sni=$tunnel_host&path=/#$idc_name-Trojan-${opt_label}-443"
        vless_link+="\nvless://$VLESS_UUID@$tunnel_host:443?encryption=none&security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-VLESS-默认Argo-443"
        trojan_link+="\ntrojan://$TROJAN_PASS@$tunnel_host:443?security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-Trojan-默认Argo-443"
    fi

    local sub_content=$(echo -e "$ss_link\n$snell_link\n$vless_link\n$trojan_link" | base64 -w0)
    mkdir -p /var/www/suoha_sub
    echo "$sub_content" > "/var/www/suoha_sub/$USERNAME.txt"
    local sub_url="http://$public_ip:$SUB_PORT$SUB_PATH$USERNAME.txt"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}  全协议代理 + S-UI 面板部署成功！${NC}"
    echo "============================================================"
    echo -e "${BLUE}【面板信息】${NC}"
    echo "  访问地址: http://$public_ip:$PANEL_PORT$PANEL_PATH"
    echo "  用户名:   $PANEL_USER"
    echo "  密码:     $PANEL_PASS"
    echo ""
    echo -e "${BLUE}【订阅信息】${NC}"
    echo "  订阅链接: $sub_url"
    echo ""
    echo -e "${BLUE}【节点信息】${NC}"
    echo "  Shadowsocks: $SS_METHOD @ $public_ip:$SS_PORT"
    echo "  Snell:       v3 @ $public_ip:$SNELL_PORT"
    echo "  VLESS:       $VLESS_UUID @ $public_ip:$VLESS_PORT"
    echo "  Trojan:      $TROJAN_PASS @ $public_ip:$TROJAN_PORT"
    echo ""
    if [ -n "$TUNNEL_URL" ]; then
        echo -e "${BLUE}【Argo 隧道】${NC}"
        echo "  隧道地址: $TUNNEL_URL"
        echo "  优选域名: $opt_domain"
        echo ""
    fi
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  1. 请妥善保存面板账号密码和订阅链接"
    echo "  2. 节点配置已写入 S-UI, 请登录面板管理(面板内点 Save 会重写 config.json)"
    echo "  3. 隧道日志: /tmp/argo_fixed.log 或 /tmp/argo_tmp.log"
    echo "  4. 卸载命令: sudo bash $0 uninstall"
    echo "============================================================"
    echo ""
}

# ========================= 主流程 =========================
main() {
    check_env
    tune_kernel
    install_cloudflared
    install_argo_router
    install_sui
    configure_sui_and_nodes
    start_argo_tunnel
    generate_and_print
    log_info "全部完成！"
}

main
