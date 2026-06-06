#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 部署脚本（对接 VPS1 的本项目 SOCKS5 出站）
# 用途：
#   客户端 -> VPS2(Hysteria2) -> VPS1(本项目 SOCKS5) -> VPS1 当前 milivpn/VPNGate 出口 -> 目标网站
#
# 默认策略：
#   TCP 走 VPS1 的 SOCKS5，UDP 直连 VPS2
#   这样最稳，适合“网页走固定落地 IP，UDP 不受上游 SOCKS5 能力影响”的场景
#
# 可选策略：
#   MODE=all_proxy
#   尝试让 TCP/UDP 都走 VPS1 的 SOCKS5。是否稳定取决于 VPS1 上游 SOCKS5 与链路对 UDP 的支持情况。

set -euo pipefail

# ---------- 默认配置 ----------
HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
DEFAULT_PORT="${DEFAULT_PORT:-22222}"
AUTH_PASSWORD="${AUTH_PASSWORD:-ieshare2025}"
CERT_FILE="${CERT_FILE:-cert.pem}"
KEY_FILE="${KEY_FILE:-key.pem}"
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"
MODE="${MODE:-tcp_proxy_udp_direct}"

# VPS1 上本项目代理配置
UPSTREAM_SOCKS_HOST="${UPSTREAM_SOCKS_HOST:-}"
UPSTREAM_SOCKS_PORT="${UPSTREAM_SOCKS_PORT:-7928}"
UPSTREAM_SOCKS_USER="${UPSTREAM_SOCKS_USER:-}"
UPSTREAM_SOCKS_PASS="${UPSTREAM_SOCKS_PASS:-}"

# 带宽与性能参数
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

# ---------- 帮助 ----------
usage() {
    cat <<'EOF'
用法：
  bash hy2.sh [监听端口] [VPS1_SOCKS_HOST] [VPS1_SOCKS_PORT]

示例：
  bash hy2.sh
  bash hy2.sh 443
  bash hy2.sh 443 1.2.3.4 7928
  MODE=all_proxy bash hy2.sh 443 1.2.3.4 7928
  UPSTREAM_SOCKS_USER=user UPSTREAM_SOCKS_PASS=pass bash hy2.sh 443 1.2.3.4 7928

环境变量：
  MODE
    tcp_proxy_udp_direct   默认，TCP 走 VPS1 SOCKS5，UDP 直连 VPS2
    all_proxy              尝试 TCP/UDP 都走 VPS1 SOCKS5

  UPSTREAM_SOCKS_HOST      VPS1 公网 IP 或域名
  UPSTREAM_SOCKS_PORT      VPS1 本项目 SOCKS5 端口，默认 7928
  UPSTREAM_SOCKS_USER      VPS1 SOCKS5 用户名，可留空
  UPSTREAM_SOCKS_PASS      VPS1 SOCKS5 密码，可留空

说明：
  1. VPS2 配的是 VPS1 的 SOCKS5 地址，不是 VPS1 当前 VPNGate 落地 IP。
  2. 以后想换出口 IP，只需要去 VPS1 的 milivpn 面板切节点。
  3. MODE=all_proxy 依赖 UDP over SOCKS5 实际可用性，不如默认模式稳。
EOF
}

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 部署脚本（对接 VPS1 本项目 SOCKS5 出站）"
echo "默认模式：TCP 走 VPS1 SOCKS5，UDP 直连 VPS2"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# ---------- 参数处理 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定监听端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供监听端口，使用默认端口: $SERVER_PORT"
fi

if [[ $# -ge 2 && -n "${2:-}" ]]; then
    UPSTREAM_SOCKS_HOST="$2"
fi

if [[ $# -ge 3 && -n "${3:-}" ]]; then
    UPSTREAM_SOCKS_PORT="$3"
fi

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

if ! validate_port "$SERVER_PORT"; then
    echo "❌ Hysteria2 监听端口无效: $SERVER_PORT"
    exit 1
fi

if [[ -z "$UPSTREAM_SOCKS_HOST" ]]; then
    echo "❌ 未设置 VPS1 的 SOCKS5 地址。"
    echo "   请用以下任一方式提供："
    echo "   1. bash hy2.sh 443 VPS1_IP 7928"
    echo "   2. UPSTREAM_SOCKS_HOST=VPS1_IP bash hy2.sh"
    exit 1
fi

if ! validate_port "$UPSTREAM_SOCKS_PORT"; then
    echo "❌ VPS1 SOCKS5 端口无效: $UPSTREAM_SOCKS_PORT"
    exit 1
fi

case "$MODE" in
    tcp_proxy_udp_direct|all_proxy)
        ;;
    *)
        echo "❌ MODE 无效: $MODE"
        echo "   可选值: tcp_proxy_udp_direct / all_proxy"
        exit 1
        ;;
esac

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine="$(uname -m | tr '[:upper:]' '[:lower:]')"
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH="$(arch_name)"
if [[ -z "$ARCH" ]]; then
    echo "❌ 无法识别 CPU 架构: $(uname -m)"
    exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [[ -f "$BIN_PATH" ]]; then
        echo "✅ Hysteria2 二进制已存在，跳过下载。"
        return
    fi

    local url
    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载 Hysteria2: $url"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行权限: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        echo "✅ 发现现有证书，复用 cert/key。"
        return
    fi

    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 生成上游 SOCKS5 配置片段 ----------
build_upstream_socks_auth_block() {
    if [[ -n "$UPSTREAM_SOCKS_USER" || -n "$UPSTREAM_SOCKS_PASS" ]]; then
        cat <<EOF
      username: "${UPSTREAM_SOCKS_USER}"
      password: "${UPSTREAM_SOCKS_PASS}"
EOF
    fi
}

build_acl_block() {
    case "$MODE" in
        tcp_proxy_udp_direct)
            cat <<'EOF'
acl:
  inline:
    - custom_proxy(network:tcp)
    - direct(network:udp)
EOF
            ;;
        all_proxy)
            cat <<'EOF'
acl:
  inline:
    - custom_proxy(all)
EOF
            ;;
    esac
}

# ---------- 写配置文件 ----------
write_config() {
    local auth_block
    local acl_block
    auth_block="$(build_upstream_socks_auth_block)"
    acl_block="$(build_acl_block)"

    cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "${UP_BANDWIDTH}"
  down: "${DOWN_BANDWIDTH}"
quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144

outbounds:
  - name: custom_proxy
    type: socks5
    socks5:
      addr: "${UPSTREAM_SOCKS_HOST}:${UPSTREAM_SOCKS_PORT}"
${auth_block}

${acl_block}
EOF

    echo "✅ 写入配置 server.yaml 成功。"
    echo "   上游 SOCKS5: ${UPSTREAM_SOCKS_HOST}:${UPSTREAM_SOCKS_PORT}"
    echo "   分流模式: ${MODE}"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    local ip
    ip="$(curl --max-time 10 https://api.ipify.org 2>/dev/null || echo "YOUR_VPS2_IP")"
    echo "$ip"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local server_ip="$1"

    echo "🎉 Hysteria2 部署成功！"
    echo "=========================================================================="
    echo "📋 VPS2 入口信息:"
    echo "   🌐 VPS2 公网 IP: $server_ip"
    echo "   🔌 Hysteria2 监听端口: $SERVER_PORT"
    echo "   🔑 Hysteria2 连接密码: $AUTH_PASSWORD"
    echo ""
    echo "📦 VPS1 上游信息:"
    echo "   🌐 VPS1 SOCKS5 地址: ${UPSTREAM_SOCKS_HOST}:${UPSTREAM_SOCKS_PORT}"
    if [[ -n "$UPSTREAM_SOCKS_USER" || -n "$UPSTREAM_SOCKS_PASS" ]]; then
        echo "   🔐 SOCKS5 认证: 已启用"
    else
        echo "   🔐 SOCKS5 认证: 未启用"
    fi
    echo "   🧭 分流模式: ${MODE}"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${server_ip}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-VPS1-SOCKS"
    echo ""
    echo "📝 说明:"
    echo "   1. 客户端连接的是 VPS2。"
    echo "   2. VPS2 再把流量转发到 VPS1 的本项目 SOCKS5。"
    echo "   3. 真正对外显示的出口 IP 由 VPS1 当前 milivpn/VPNGate 节点决定。"
    echo "   4. 以后想换落地 IP，只需要去 VPS1 的 milivpn 切节点，不用改 VPS2。"
    if [[ "$MODE" == "tcp_proxy_udp_direct" ]]; then
        echo "   5. 当前模式下只有 TCP 固定走 VPS1 出口，UDP 仍然从 VPS2 直连。"
    else
        echo "   5. 当前模式尝试让 TCP/UDP 都走 VPS1，但 UDP 稳定性取决于上游支持。"
    fi
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config

    local server_ip
    server_ip="$(get_server_ip)"
    print_connection_info "$server_ip"

    echo "🚀 启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
