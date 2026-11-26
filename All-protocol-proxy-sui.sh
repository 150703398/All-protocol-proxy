#!/bin/bash
# ===================================================================
# All-protocol-proxy-sui.sh
# 一键全协议部署 + S-UI 面板管理合并版
# 功能: 4K内核调优 + S-UI面板(接管sing-box) + Cloudflare Argo隧道 + Snell/SS节点
# 架构: sing-box 内核由 S-UI 面板统一管理, 避免配置互相覆盖
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
SUB_PORT_FILE="/etc/suoha_sub_port"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared-linux"

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
while [[ $# -gt 0 ]]; do
    case $1 in
        uninstall)
            UNINSTALL=1
            shift
            ;;
        --tunnel-token)
            TUNNEL_TOKEN="$2"
            shift 2
            ;;
        --tunnel-hostname)
            TUNNEL_HOSTNAME="$2"
            shift 2
            ;;
        --tunnel-local-port)
            TUNNEL_LOCAL_PORT="$2"
            shift 2
            ;;
        --panel-port)
            PANEL_PORT="$2"
            shift 2
            ;;
        --panel-path)
            PANEL_PATH="$2"
            shift 2
            ;;
        --panel-sub-port)
            SUB_PORT="$2"
            shift 2
            ;;
        --panel-sub-path)
            SUB_PATH="$2"
            shift 2
            ;;
        --panel-user)
            PANEL_USER="$2"
            shift 2
            ;;
        --panel-pass)
            PANEL_PASS="$2"
            shift 2
            ;;
        --panel-domain)
            PANEL_DOMAIN="$2"
            shift 2
            ;;
        *)
            log_error "未知参数: $1"
            exit 1
            ;;
    esac
done

# ========================= 卸载 =========================
do_uninstall() {
    log_step "开始卸载"

    log_info "停止 S-UI 服务..."
    if command -v s-ui &>/dev/null; then
        s-ui stop 2>/dev/null || true
        s-ui uninstall 2>/dev/null || true
    fi
    systemctl disable --now s-ui 2>/dev/null || true
    rm -f /etc/systemd/system/s-ui.service

    log_info "停止 sing-box 服务..."
    systemctl disable --now sing-box 2>/dev/null || true
    rm -f /etc/systemd/system/sing-box.service
    pkill -f sing-box 2>/dev/null || true

    log_info "停止 cloudflared / argo_router..."
    pkill -f cloudflared 2>/dev/null || true
    pkill -f argo_router 2>/dev/null || true

    log_info "删除文件..."
    rm -rf "$SUI_DIR"
    rm -rf "$INSTALL_DIR"
    rm -f /etc/suoha_sub_port
    rm -rf /var/www/suoha_sub
    rm -f /etc/sysctl.d/99-suoha-4k.conf
    rm -f "$CLOUDFLARED_BIN"

    log_info "重载内核参数与服务..."
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload

    log_info "卸载完成"
}

if [[ "${UNINSTALL:-0}" == "1" ]]; then
    do_uninstall
    exit 0
fi

# ========================= 环境检查 =========================
check_env() {
    log_step "环境检查"

    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行 (sudo bash $0)"
        exit 1
    fi

    local os_info=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        os_info="$ID $VERSION_ID"
    fi
    log_info "系统: ${os_info:-未知}"

    local arch=$(uname -m)
    case $arch in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="arm" ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
    log_info "架构: $ARCH"

    if ! command -v curl &>/dev/null; then
        log_info "安装 curl..."
        if command -v apt-get &>/dev/null; then
            apt-get update -y && apt-get install -y curl
        elif command -v yum &>/dev/null; then
            yum install -y curl
        elif command -v apk &>/dev/null; then
            apk add --no-cache curl
        else
            log_error "无法安装 curl, 请手动安装"
            exit 1
        fi
    fi
}

# ========================= 4K 内核调优 =========================
tune_kernel() {
    log_step "4K 内核调优 (BBR + 拥塞控制)"

    cat > /etc/sysctl.d/99-suoha-4k.conf <<'EOF'
# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 队列与缓冲
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65536
net.ipv4.tcp_max_syn_backlog = 65536
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_rmem = 4096 65536 16777216

# 连接复用与超时
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5

# 文件句柄
fs.file-max = 1000000
EOF

    sysctl --system >/dev/null 2>&1 || true
    log_info "内核参数已应用"
}

# ========================= 安装 cloudflared =========================
install_cloudflared() {
    log_step "安装 cloudflared"

    if [[ -f "$CLOUDFLARED_BIN" ]]; then
        log_info "cloudflared 已存在, 跳过下载"
        return
    fi

    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    log_info "下载: $url"
    curl -fsSL -o "$CLOUDFLARED_BIN" "$url"
    chmod +x "$CLOUDFLARED_BIN"
    log_info "cloudflared 安装完成"
}

# ========================= 安装 S-UI 面板 =========================
install_sui() {
    log_step "安装 S-UI 面板"

    if [[ -d "$SUI_DIR" ]] && command -v s-ui &>/dev/null; then
        log_warn "S-UI 已安装, 跳过安装步骤"
        return
    fi

    local install_url="https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh"
    # 官方 S-UI 安装器
    install_url="https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"

    log_info "下载 S-UI 安装器..."
    curl -fsSL -o /tmp/sui-install.sh "$install_url"

    log_info "执行安装 (非交互模式)..."
    bash /tmp/sui-install.sh install

    if [[ ! -f "$SUI_DIR/s-ui" ]]; then
        log_error "S-UI 安装失败, 未找到 $SUI_DIR/s-ui"
        exit 1
    fi

    ln -sf "$SUI_DIR/s-ui" /usr/local/bin/s-ui 2>/dev/null || true
    log_info "S-UI 安装完成"
}

# ========================= 配置 S-UI =========================
random_str() {
    local len=${1:-16}
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

configure_sui() {
    log_step "配置 S-UI 面板"

    [[ -z "$PANEL_USER" ]] && PANEL_USER="admin_$(random_str 6)"
    [[ -z "$PANEL_PASS" ]] && PANEL_PASS="$(random_str 16)"

    log_info "面板端口: $PANEL_PORT"
    log_info "面板路径: $PANEL_PATH"
    log_info "订阅端口: $SUB_PORT"
    log_info "订阅路径: $SUB_PATH"

    # 通过 s-ui 命令行设置基础配置
    s-ui setting -port "$PANEL_PORT" >/dev/null 2>&1 || true
    s-ui setting -webBasePath "$PANEL_PATH" >/dev/null 2>&1 || true
    s-ui setting -subPort "$SUB_PORT" >/dev/null 2>&1 || true
    s-ui setting -subBasePath "$SUB_PATH" >/dev/null 2>&1 || true

    # 设置管理员账号
    if [[ -f "$SUI_DIR/db/s-ui.db" ]] && command -v sqlite3 &>/dev/null; then
        local hashed=$(openssl passwd -aprjan "$PANEL_PASS" 2>/dev/null || echo "")
        if [[ -n "$hashed" ]]; then
            sqlite3 "$SUI_DIR/db/s-ui.db" \
                "UPDATE users SET username='$PANEL_USER', password='$hashed' WHERE id=1;" 2>/dev/null || true
        fi
    fi

    echo "$SUB_PORT" > "$SUB_PORT_FILE"

    s-ui restart >/dev/null 2>&1 || true
    sleep 3
    log_info "S-UI 配置完成"
}

# ========================= 通过面板 API 创建节点 =========================
wait_panel_ready() {
    local retries=0
    local max=30
    while [[ $retries -lt $max ]]; do
        if curl -sf "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}" >/dev/null 2>&1; then
            return 0
        fi
        retries=$((retries + 1))
        sleep 1
    done
    log_warn "面板 HTTP 探测超时, 继续尝试调用 API"
    return 1
}

panel_login() {
    local resp
    resp=$(curl -sf -X POST "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$PANEL_USER\",\"password\":\"$PANEL_PASS\"}" 2>/dev/null || echo "")

    if [[ -z "$resp" ]]; then
        log_warn "面板登录失败, 无法自动创建节点"
        return 1
    fi

    COOKIE_FILE=$(mktemp)
    curl -sf -c "$COOKIE_FILE" -X POST "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$PANEL_USER\",\"password\":\"$PANEL_PASS\"}" >/dev/null 2>&1 || return 1
    return 0
}

panel_api() {
    local method=$1
    local path=$2
    local data=$3
    local url="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}api/${path}"

    if [[ "$method" == "GET" ]]; then
        curl -sf -b "$COOKIE_FILE" "$url" 2>/dev/null
    else
        curl -sf -b "$COOKIE_FILE" -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "$data" 2>/dev/null
    fi
}

create_nodes_via_panel() {
    log_step "通过面板创建 SS / Snell 节点"

    wait_panel_ready || true

    if ! panel_login; then
        log_warn "跳过自动建节点, 请手动在面板中创建"
        return 1
    fi

    # ---- Shadowsocks 入站 ----
    local ss_port=$((30000 + RANDOM % 10000))
    local ss_method="2022-blake3-aes-128-gcm"
    local ss_pass
    if command -v sing-box &>/dev/null; then
        ss_pass=$(sing-box generate rand --base64 16 2>/dev/null || random_str 16)
    else
        ss_pass=$(random_str 16)
    fi

    log_info "创建 Shadowsocks 入站 (端口 $ss_port)..."
    local ss_json=$(cat <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "expiryTime": 0,
  "enable": true,
  "limitIp": 0,
  "clientIp": "",
  "remark": "SS-直连",
  "protocol": "shadowsocks",
  "port": $ss_port,
  "settings": {
    "method": "$ss_method",
    "password": "$ss_pass",
    "network": "tcp,udp",
    "udpOverTcp": false
  }
}
EOF
)
    panel_api POST "inbound/add" "$ss_json" >/dev/null 2>&1 || log_warn "SS 入站创建失败"

    # ---- Snell 入站 ----
    local snell_port=$((30000 + RANDOM % 10000))
    local snell_psk
    snell_psk=$(random_str 32)

    log_info "创建 Snell 入站 (端口 $snell_port)..."
    local snell_json=$(cat <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "expiryTime": 0,
  "enable": true,
  "limitIp": 0,
  "clientIp": "",
  "remark": "Snell-直连",
  "protocol": "snell",
  "port": $snell_port,
  "settings": {
    "psk": "$snell_psk",
    "version": 3,
    "network": "tcp"
  }
}
EOF
)
    panel_api POST "inbound/add" "$snell_json" >/dev/null 2>&1 || log_warn "Snell 入站创建失败"

    # ---- 创建用户并绑定 ----
    local username="user_$(random_str 6)"
    log_info "创建用户: $username"
    local user_json=$(cat <<EOF
{
  "username": "$username",
  "password": "$(random_str 12)",
  "total": 0,
  "expiryTime": 0,
  "enable": true,
  "limitIp": 0,
  "traffic": 0,
  "inbounds": [
    {"tag": "SS-直连", "port": $ss_port, "protocol": "shadowsocks"},
    {"tag": "Snell-直连", "port": $snell_port, "protocol": "snell"}
  ]
}
EOF
)
    panel_api POST "client/add" "$user_json" >/dev/null 2>&1 || log_warn "用户创建失败"

    # 保存配置
    panel_api POST "config/save" '{}' >/dev/null 2>&1 || true

    rm -f "$COOKIE_FILE" 2>/dev/null || true

    # 记录供后续输出
    echo "$ss_port|$ss_pass|$snell_port|$snell_psk|$username" > /tmp/sui_nodes_info
    log_info "节点创建完成"
}

# ========================= Argo 隧道 =========================
get_public_ip() {
    local ip
    ip=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null) || \
    ip=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null) || \
    ip=$(curl -sf --max-time 5 https://ipinfo.io/ip 2>/dev/null) || \
    ip="127.0.0.1"
    echo "$ip"
}

get_idc_name() {
    local ip=$1
    local org
    org=$(curl -sf --max-time 5 "http://ip-api.com/json/$ip?fields=org" 2>/dev/null | \
          sed 's/.*"org":"\([^"]*\)".*/\1/' 2>/dev/null) || org=""
    if [[ -z "$org" ]]; then
        org="VPS"
    fi
    # 简化机房名
    echo "$org" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]' | head -c 12
}

start_fixed_tunnel() {
    log_step "启动固定命名隧道"

    if [[ -z "$TUNNEL_HOSTNAME" ]] || [[ -z "$TUNNEL_TOKEN" ]]; then
        log_error "判定为固定隧道, 但 TUNNEL_HOSTNAME 或 TUNNEL_TOKEN 为空!"
        log_error "请两者都填写, 或全部留空以改用随机临时隧道。"
        exit 1
    fi

    [[ -z "$TUNNEL_LOCAL_PORT" ]] && TUNNEL_LOCAL_PORT="8001"

    echo ""
    echo "================ 固定命名隧道 · 控制台配置对照 ================"
    echo "请到 Cloudflare Zero Trust -> Networks -> Tunnels -> (你的隧道) -> Public Hostname 核对:"
    echo "  Hostname : $TUNNEL_HOSTNAME"
    echo "  Service  : http://localhost:${TUNNEL_LOCAL_PORT}    <- 端口必须等于 TUNNEL_LOCAL_PORT(${TUNNEL_LOCAL_PORT})"
    echo "二者不一致会导致隧道虽连上但访问 502 / 连不上。核对无误后脚本继续。"
    echo "================================================================"
    echo ""

    # 本机监听预检
    if command -v ss &>/dev/null; then
        if ! ss -tlnp 2>/dev/null | grep -q ":${TUNNEL_LOCAL_PORT} "; then
            log_warn "本机 ${TUNNEL_LOCAL_PORT} 端口未检测到监听, 隧道连上后可能 502"
        fi
    elif command -v netstat &>/dev/null; then
        if ! netstat -tlnp 2>/dev/null | grep -q ":${TUNNEL_LOCAL_PORT} "; then
            log_warn "本机 ${TUNNEL_LOCAL_PORT} 端口未检测到监听, 隧道连上后可能 502"
        fi
    fi

    local log_file="/tmp/argo_fixed.log"
    rm -f "$log_file"

    # 全局参数 --no-autoupdate 必须在子命令之前
    nohup "$CLOUDFLARED_BIN" --no-autoupdate tunnel run --token "$TUNNEL_TOKEN" \
        > "$log_file" 2>&1 &
    local tunnel_pid=$!
    echo "$tunnel_pid" > "$INSTALL_DIR/argo_fixed.pid"

    local waited=0
    local max_wait=30
    while [[ $waited -lt $max_wait ]]; do
        if ! kill -0 "$tunnel_pid" 2>/dev/null; then
            log_error "固定命名隧道进程已退出, 建立失败。请排查:"
            log_error "  1) TUNNEL_TOKEN

---
当前脚本缺少Argo路由器分流逻辑，需要我帮你补全并重新生成完整的S-UI合并版脚本吗？
<websource>inline_action_reply_1</websource>
