#!/bin/bash
# ===================================================================
# All-protocol-proxy-sui.sh
# 一键全协议部署 + S-UI 面板管理合并版
# 功能: 4K内核调优 + S-UI面板(接管sing-box) + Cloudflare Argo隧道 + 路由器分流
#       + Snell/SS/VLESS/Trojan 节点 + 优选域名
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
while ; do
    case "$1" in
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
        "")
            shift
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
    rm -f "$INSTALL_DIR"/*.pid 2>/dev/null || true

    log_info "删除文件..."
    rm -rf "$SUI_DIR"
    rm -rf "$INSTALL_DIR"
    rm -f /etc/suoha_sub_port
    rm -rf /var/www/suoha_sub
    rm -f /etc/sysctl.d/99-suoha-4k.conf
    rm -f "$CLOUDFLARED_BIN"
    rm -f "$ARGO_ROUTER_BIN"
    rm -f /tmp/sui_nodes_info /tmp/argo_fixed.log /tmp/argo_tmp.log

    log_info "重载内核参数与服务..."
    sysctl --system >/dev/null 2>&1 || true
    systemctl daemon-reload

    log_info "卸载完成"
}

if ; then
    do_uninstall
    exit 0
fi

# ========================= 环境检查 =========================
check_env() {
    log_step "环境检查"

    if ; then
        log_error "请使用 root 权限运行 (sudo bash $0)"
        exit 1
    fi

    local os_info=""
    if ; then
        . /etc/os-release
        os_info="$ID $VERSION_ID"
    fi
    log_info "系统: ${os_info:-未知}"

    local arch
    arch=$(uname -m)
    case "$arch" in
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

    mkdir -p "$INSTALL_DIR"
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

    if  && ; then
        log_info "cloudflared 已存在, 跳过下载"
        return
    fi

    local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
    log_info "下载: $url"
    curl -fsSL -o "$CLOUDFLARED_BIN" "$url"
    chmod +x "$CLOUDFLARED_BIN"
    log_info "cloudflared 安装完成"
}

# ========================= 安装 argo_router =========================
install_argo_router() {
    log_step "安装 argo_router (分流路由器)"

    if  && ; then
        log_info "argo_router 已存在, 跳过下载"
        return
    fi

    local base_url="https://github.com/fscarmen/argo-go/releases/latest/download"
    local bin_name="argo-go-linux-${ARCH}"
    local url="${base_url}/${bin_name}"

    log_info "下载: $url"
    if curl -fsSL -o "$ARGO_ROUTER_BIN" "$url" 2>/dev/null; then
        chmod +x "$ARGO_ROUTER_BIN"
        log_info "argo_router 安装完成"
    else
        log_warn "argo_router 下载失败, 将使用单隧道模式（不分流）"
        ARGO_ROUTER_BIN=""
    fi
}

# ========================= 安装 S-UI 面板 =========================
install_sui() {
    log_step "安装 S-UI 面板"

    if  && ; then
        log_warn "S-UI 已安装, 跳过安装步骤"
        return
    fi

    local install_url="https://raw.githubusercontent.com/alireza0/s-ui/master/install.sh"

    log_info "下载 S-UI 安装器..."
    curl -fsSL -o /tmp/sui-install.sh "$install_url"

    log_info "执行安装 (非交互模式)..."
    bash /tmp/sui-install.sh install

    if ; then
        log_error "S-UI 安装失败, 未找到 $SUI_DIR/s-ui"
        exit 1
    fi

    ln -sf "$SUI_DIR/s-ui" /usr/local/bin/s-ui 2>/dev/null || true
    log_info "S-UI 安装完成"
}

# ========================= 工具函数 =========================
random_str() {
    local len=${1:-16}
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

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
    if ; then
        org="VPS"
    fi
    echo "$org" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]' | head -c 12
}

# ========================= 配置 S-UI =========================
configure_sui() {
    log_step "配置 S-UI 面板"

     && PANEL_USER="admin_$(random_str 6)"
     && PANEL_PASS="$(random_str 16)"

    log_info "面板端口: $PANEL_PORT"
    log_info "面板路径: $PANEL_PATH"
    log_info "订阅端口: $SUB_PORT"
    log_info "订阅路径: $SUB_PATH"

    s-ui setting -port "$PANEL_PORT" >/dev/null 2>&1 || true
    s-ui setting -webBasePath "$PANEL_PATH" >/dev/null 2>&1 || true
    s-ui setting -subPort "$SUB_PORT" >/dev/null 2>&1 || true
    s-ui setting -subBasePath "$SUB_PATH" >/dev/null 2>&1 || true

    if  && command -v sqlite3 &>/dev/null; then
        local hashed
        hashed=$(openssl passwd -aprjan "$PANEL_PASS" 2>/dev/null || echo "")
        if ; then
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
    while ; do
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

    if ; then
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

    if ; then
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

    # ---- VLESS 入站（供 Argo 隧道回源）----
    local vless_port=$((30000 + RANDOM % 10000))
    local vless_uuid
    vless_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || random_str 36)

    log_info "创建 VLESS 入站 (端口 $vless_port)..."
    local vless_json=$(cat <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "expiryTime": 0,
  "enable": true,
  "limitIp": 0,
  "clientIp": "",
  "remark": "VLESS-Argo",
  "protocol": "vless",
  "port": $vless_port,
  "settings": {
    "clients": [
      {
        "id": "$vless_uuid",
        "flow": "",
        "email": "vless@argo"
      }
    ],
    "decryption": "none",
    "network": "tcp,udp",
    "security": "none"
  }
}
EOF
)
    panel_api POST "inbound/add" "$vless_json" >/dev/null 2>&1 || log_warn "VLESS 入站创建失败"

    # ---- Trojan 入站（供 Argo 隧道回源）----
    local trojan_port=$((30000 + RANDOM % 10000))
    local trojan_pass
    trojan_pass=$(random_str 16)

    log_info "创建 Trojan 入站 (端口 $trojan_port)..."
    local trojan_json=$(cat <<EOF
{
  "up": 0,
  "down": 0,
  "total": 0,
  "expiryTime": 0,
  "enable": true,
  "limitIp": 0,
  "clientIp": "",
  "remark": "Trojan-Argo",
  "protocol": "trojan",
  "port": $trojan_port,
  "settings": {
    "clients": [
      {
        "password": "$trojan_pass",
        "email": "trojan@argo"
      }
    ],
    "network": "tcp,udp"
  }
}
EOF
)
    panel_api POST "inbound/add" "$trojan_json" >/dev/null 2>&1 || log_warn "Trojan 入站创建失败"

    # ---- 创建用户并绑定全部入站 ----
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
    {"tag": "SS-直连", "port":

[(doc_common_card_1)]

    # ---- 创建用户并绑定全部入站 ----
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
    {"tag": "SS-直连", "port": $ss_port},
    {"tag": "Snell-直连", "port": $snell_port},
    {"tag": "VLESS-Argo", "port": $vless_port},
    {"tag": "Trojan-Argo", "port": $trojan_port}
  ]
}
EOF
)
    panel_api POST "client/add" "$user_json" >/dev/null 2>&1 || log_warn "用户创建失败"

    # 重启使配置生效
    s-ui restart >/dev/null 2>&1 || true
    sleep 2

    # 保存节点信息供后续输出
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

    log_info "节点创建完成"
}

# ========================= 启动 Argo 隧道 =========================
start_argo_tunnel() {
    log_step "启动 Cloudflare Argo 隧道"

    # 读取节点信息
    if ; then
        log_error "未找到节点信息, 请先执行节点创建"
        return 1
    fi
    source /tmp/sui_nodes_info

    local public_ip
    public_ip=$(get_public_ip)
    local idc_name
    idc_name=$(get_idc_name "$public_ip")

    # 确定回源端口（优先 VLESS，其次 Trojan）
    local local_port="${TUNNEL_LOCAL_PORT:-$VLESS_PORT}"

    # 生成临时隧道或固定隧道
    if ; then
        log_info "使用固定隧道模式 (Token 已提供)"
        
        # 写入 cloudflared 配置
        mkdir -p /etc/cloudflared
        cat > /etc/cloudflared/config.yml <<EOF
tunnel: $TUNNEL_TOKEN
credentials-file: /etc/cloudflared/creds.json

ingress:
  - hostname: $TUNNEL_HOSTNAME
    service: http://127.0.0.1:$local_port
  - service: http_status:404
EOF

        # 启动固定隧道
        nohup "$CLOUDFLARED_BIN" tunnel run --config /etc/cloudflared/config.yml \
            > /tmp/argo_fixed.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"
        
        log_info "固定隧道已启动: https://$TUNNEL_HOSTNAME"
        TUNNEL_URL="https://$TUNNEL_HOSTNAME"
    else
        log_info "使用临时隧道模式"
        
        # 启动临时隧道
        nohup "$CLOUDFLARED_BIN" tunnel --no-autoupdate --url http://127.0.0.1:$local_port \
            > /tmp/argo_tmp.log 2>&1 &
        echo $! > "$INSTALL_DIR/cloudflared.pid"
        
        # 等待隧道建立并提取 URL
        sleep 5
        TUNNEL_URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/argo_tmp.log | head -1)
        
        if ; then
            log_warn "临时隧道 URL 提取失败, 请查看 /tmp/argo_tmp.log"
            TUNNEL_URL="待获取"
        else
            log_info "临时隧道已启动: $TUNNEL_URL"
        fi
    fi

    # 如果有 argo_router，启动分流
    if  && ; then
        log_info "启动 Argo 分流路由器..."
        
        # 生成路由器配置
        cat > "$INSTALL_DIR/argo_router.json" <<EOF
{
  "listen": "127.0.0.1:8080",
  "routes": [
    {
      "match": "domain",
      "value": "*.google.com",
      "target": "http://127.0.0.1:$VLESS_PORT"
    },
    {
      "match": "domain",
      "value": "*.cloudflare.com",
      "target": "http://127.0.0.1:$TROJAN_PORT"
    },
    {
      "match": "default",
      "target": "http://127.0.0.1:$VLESS_PORT"
    }
  ]
}
EOF

        nohup "$ARGO_ROUTER_BIN" -config "$INSTALL_DIR/argo_router.json" \
            > /tmp/argo_router.log 2>&1 &
        echo $! > "$INSTALL_DIR/argo_router.pid"
        
        log_info "分流路由器已启动 (监听 127.0.0.1:8080)"
    fi
}

# ========================= 生成订阅链接 =========================
generate_subscriptions() {
    log_step "生成订阅链接"

    source /tmp/sui_nodes_info

    local public_ip
    public_ip=$(get_public_ip)
    local idc_name
    idc_name=$(get_idc_name "$public_ip")

    # 获取优选域名
    local opt_domain="${opt_domains[0]}"
    local opt_label="${opt_labels[0]}"

    # 构造节点链接
    local ss_link="ss://$(echo -n "$SS_METHOD:$SS_PASS" | base64 -w0)@$public_ip:$SS_PORT?plugin=obfs-local;obfs=http;obfs-host=www.baidu.com#$idc_name-SS-直连"
    local snell_link="snell://$SNELL_PSK@$public_ip:$SNELL_PORT?version=3#$idc_name-Snell-直连"
    
    local vless_link="vless://$VLESS_UUID@$public_ip:$VLESS_PORT?encryption=none&security=none&type=tcp#$idc_name-VLESS-直连"
    local trojan_link="trojan://$TROJAN_PASS@$public_ip:$TROJAN_PORT?security=none&type=tcp#$idc_name-Trojan-直连"

    # 如果有隧道，生成隧道节点
    if ; then
        local tunnel_host
        if [[ "$TUNNEL_URL" == *"trycloudflare.com"* ]]; then
            tunnel_host=$(echo "$TUNNEL_URL" | sed 's|https://||')
        else
            tunnel_host="$TUNNEL_HOSTNAME"
        fi
        
        vless_link+="\nvless://$VLESS_UUID@$tunnel_host:443?encryption=none&security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-VLESS-Argo"
        trojan_link+="\ntrojan://$TROJAN_PASS@$tunnel_host:443?security=tls&type=ws&host=$tunnel_host&path=/#$idc_name-Trojan-Argo"
    fi

    # 生成订阅内容
    local sub_content=$(echo -e "$ss_link\n$snell_link\n$vless_link\n$trojan_link" | base64 -w0)

    # 写入订阅文件
    mkdir -p /var/www/suoha_sub
    echo "$sub_content" > "/var/www/suoha_sub/$USERNAME.txt"

    # 保存订阅信息
    cat >> /tmp/sui_nodes_info <<EOF
SUB_URL=http://$public_ip:$SUB_PORT$SUB_PATH$USERNAME.txt
TUNNEL_URL=$TUNNEL_URL
EOF

    log_info "订阅链接已生成"
}

# ========================= 输出最终信息 =========================
print_final_info() {
    log_step "部署完成"

    source /tmp/sui_nodes_info

    local public_ip
    public_ip=$(get_public_ip)

    echo ""
    echo "============================================================"
    echo -e "${GREEN}  全协议代理 + S-UI 面板部署成功！${NC}"
    echo "============================================================"
    echo ""
    echo -e "${BLUE}【面板信息】${NC}"
    echo "  访问地址: http://$public_ip:$PANEL_PORT$PANEL_PATH"
    echo "  用户名:   $PANEL_USER"
    echo "  密码:     $PANEL_PASS"
    echo ""
    echo -e "${BLUE}【订阅信息】${NC}"
    echo "  订阅链接: $SUB_URL"
    echo ""
    echo -e "${BLUE}【节点信息】${NC}"
    echo "  Shadowsocks: $SS_METHOD @ $public_ip:$SS_PORT"
    echo "  Snell:       v3 @ $public_ip:$SNELL_PORT"
    echo "  VLESS:       $VLESS_UUID @ $public_ip:$VLESS_PORT"
    echo "  Trojan:      $TROJAN_PASS @ $public_ip:$TROJAN_PORT"
    echo ""
    if ; then
        echo -e "${BLUE}【Argo 隧道】${NC}"
        echo "  隧道地址: $TUNNEL_URL"
        echo ""
    fi
    echo -e "${YELLOW}【重要提示】${NC}"
    echo "  1. 请妥善保存面板账号密码和订阅链接"
    echo "  2. 节点配置由 S-UI 面板统一管理"
    echo "  3. 隧道日志: /tmp/argo_fixed.log 或 /tmp/argo_tmp.log"
    echo "  4. 卸载命令: sudo bash $0 uninstall"
    echo "============================================================"
    echo ""
}

# ========================= 主流程 =========================
main() {
    log_step "开始部署"
    
    check_env
    tune_kernel
    install_cloudflared
    install_argo_router
    install_sui
    configure_sui
    create_nodes_via_panel
    start_argo_tunnel
    generate_subscriptions
    print_final_info
    
    log_info "全部完成！"
}

main
