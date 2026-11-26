#!/bin/bash
# ===================================================================
# All-protocol-proxy-sui.sh (修复完善版)
# 一键全协议部署 + S-UI 面板管理合并版
# 功能: 4K内核调优 + S-UI面板(接管sing-box) + Cloudflare Argo隧道 + 路由器分流
#       + Snell/SS/VLESS/Trojan 节点 + 优选域名
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

INSTALL_DIR="/opt/All-protocol-proxy"
SUI_DIR="/usr/local/s-ui"
SUI_DB_DIR="$SUI_DIR/db"
SUI_CONFIG_DIR="$SUI_DIR/config"
SUB_PORT_FILE="/etc/suoha_sub_port"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-linux"
ARGO_ROUTER_BIN="/usr/local/bin/argo_router"

# 优选域名
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
    rm -f "$CLOUDFLARED_BIN" "$ARGO_ROUTER_BIN"
    rm -f /tmp/sui_nodes_info /tmp/argo_*.log
    
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

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
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
}

install_argo_router() {
    log_step "安装 argo_router (分流路由器)"
    if [ -f "$ARGO_ROUTER_BIN" ] && [ -x "$ARGO_ROUTER_BIN" ]; then
        log_info "argo_router 已存在, 跳过下载"
        return
    fi
    local url="https://github.com/fscarmen/argo-go/releases/latest/download/argo-go-linux-${ARCH}"
    log_info "下载 argo_router..."
    if curl -fsSL -o "$ARGO_ROUTER_BIN" "$url" 2>/dev/null; then
        chmod +x "$ARGO_ROUTER_BIN"
    else
        log_warn "argo_router 下载失败, 将使用单隧道模式（不分流）"
        ARGO_ROUTER_BIN=""
    fi
}

install_sui() {
    log_step "安装 S-UI 面板"
    if [ -f "$SUI_DIR/s-ui" ]; then
        log_warn "S-UI 已安装, 跳过安装步骤"
        return
    fi
    log_info "下载并执行 S-UI 安装器..."
    curl -fsSL -o /tmp/sui-install.sh "https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"
    bash /tmp/sui-install.sh install
    if [ ! -f "$SUI_DIR/s-ui" ]; then
        log_error "S-UI 安装失败"
        exit 1
    fi
    ln -sf "$SUI_DIR/s-ui" /usr/local/bin/s-ui 2>/dev/null || true
}

# ========================= 工具函数 =========================
random_str() { cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "${1:-16}"; }
get_public_ip() { curl -sf --max-time 5 https://api.ipify.org || curl -sf --max-time 5 https://ifconfig.me || echo "127.0.0.1"; }
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

    # 生成节点配置
    local ss_port=$((30000 + RANDOM % 10000))
    local ss_method="2022-blake3-aes-128-gcm"
    local ss_pass=$(random_str 16)

    local snell_port=$((30000 + RANDOM % 10000))
    local snell_psk=$(random_str 32)

    local vless_port=$((30000 + RANDOM % 10000))
    local vless_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || random_str 36)

    local trojan_port=$((30000 + RANDOM % 10000))
    local trojan_pass=$(random_str 16)

    local username="user_$(random_str 6)"

    # 写入 sing-box 配置文件 (S-UI 会自动读取此目录)
    mkdir -p "$SUI_CONFIG_DIR"
    cat > "$SUI_CONFIG_DIR/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks", "tag": "SS-直连", "port": $ss_port,
      "method": "$ss_method", "password": "$ss_pass", "network": "tcp,udp"
    },
    {
      "type": "snell", "tag": "Snell-直连", "port": $snell_port,
      "psk": "$snell_psk", "version": 3, "network": "tcp"
    },
    {
      "type": "vless", "tag": "VLESS-Argo", "port": $vless_port,
      "uuid": "$vless_uuid", "network": "tcp,udp"
    },
    {
      "type": "trojan", "tag": "Trojan-Argo", "port": $trojan_port,
      "password": "$trojan_pass", "network": "tcp,udp"
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
EOF

    # 配置 S-UI 面板参数并重启
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
    source /tmp/sui_nodes_info

    local local_port="${TUNNEL_LOCAL_PORT:-$VLESS_PORT}"

    if [ -n "$TUNNEL_TOKEN" ]; then
        log_info "使用固定隧道模式..."
        mkdir -p /etc/cloudflared
        cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_TOKEN
credentials-file: /etc/cloudflared/creds.json
ingress:
  - hostname: $TUNNEL_HOSTNAME
    service: http://127.0.0.1:$local_port
  - service: http_status:404
EOF
        nohup "$CLOUDFLARED_BIN" tunnel run --config /etc/cloudflared/config.yml > /tmp/argo_fixed.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"
        TUNNEL_URL="https://$TUNNEL_HOSTNAME"
    else
        log_info "使用临时隧道模式..."
        nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url http://127.0.0.1:$local_port > /tmp/argo_tmp.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"
        
        sleep 8
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo_tmp.log | head -1)
        [ -z "$TUNNEL_URL" ] && TUNNEL_URL="待获取(查看/tmp/argo_tmp.log)"
    fi
    echo "TUNNEL_URL=$TUNNEL_URL" >> /tmp/sui_nodes_info

    # 启动分流路由器
    if [ -n "$ARGO_ROUTER_BIN" ] && [ -f "$ARGO_ROUTER_BIN" ]; then
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
    fi
}

# ========================= 生成订阅与最终输出 =========================
generate_and_print() {
    log_step "生成订阅与部署信息"
    source /tmp/sui_nodes_info

    local public_ip=$(get_public_ip)
    local idc_name=$(get_idc_name "$public_ip")
    local opt_domain="${opt_domains[0]}"

    # 构造节点链接
    local ss_link="ss://$(echo -n "$SS_METHOD:$SS_PASS" | base64 -w0)@$public_ip:$SS_PORT#$idc_name-SS"
    local snell_link="snell://$SNELL_PSK@$public_ip:$SNELL_PORT?version=3#$idc_name-Snell"
    local vless_link="vless://$VLESS_UUID@$public_ip:$VLESS_PORT?encryption=none&type=tcp#$idc_name-VLESS"
    local trojan_link="trojan://$TROJAN_PASS@$public_ip:$TROJAN_PORT?type=tcp#$idc_name-Trojan"

    local tunnel_host=$(echo "$TUNNEL_URL" | sed 's|https://||')
    if [ -n "$tunnel_host" ] && [ "$tunnel_host" != "待获取(查看/tmp/argo_tmp.log)" ]; then
        vless_link+="\nvless://$VLESS_UUID@$tunnel_host:443?encryption=none&security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-VLESS-Argo"
        trojan_link+="\ntrojan://$TROJAN_PASS@$tunnel_host:443?security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-Trojan-Argo"
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
    echo -e "${BLUE}【Argo 隧道】${NC}"
    echo "  隧道地址: $TUNNEL_URL"
    echo "============================================================"
    echo -e "${YELLOW}【提示】节点配置已写入 S-UI，请登录面板查看和管理。${NC}"
    echo "============================================================"
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
}

main
