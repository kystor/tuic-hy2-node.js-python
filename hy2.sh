#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（修复 Cloudflare 验证 IP 分裂问题）
# 适用于超低内存环境（32-64MB）

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222
AUTH_PASSWORD="ieshare2025"
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.bing.com"
ALPN="h3"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（带精准域名分流与 QUIC 拦截）"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    # 保留 curl 默认输出，不屏蔽进度信息
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    # 保留 openssl 默认输出，不屏蔽子进程信息
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
write_config() {
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
  up: "200mbps"
  down: "200mbps"
quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144

# === 代理出口配置 ===
outbounds:
  - name: custom_proxy
    type: socks5
    socks5:
      addr: "66.181.36.237:25556"

# === 🌟 核心防拦截规则 (ACL) ===
acl:
  inline:
    # 1. 允许 DNS 解析请求 (53端口) 直连，防止断网
    - direct(port:53)
    
    # 2. 【核心】拦截所有其他的 UDP 流量！
    # 作用：强行关闭浏览器对 Cloudflare 网站的 HTTP/3 尝试，防止出现面板 IP 和代理 IP 分裂。
    - reject(network:udp)
    
    # 3. 把你需要【必须使用家宽 IP 访问的网站】填在下面
    # 以下网站会强制走 66.181.36.237 代理
    - custom_proxy(domain:ipify.org)
    - custom_proxy(domain:chatgpt.com)
    - custom_proxy(domain:openai.com)
    - custom_proxy(domain:run.freecloud.ltd)
    # 你可以按照上面的格式继续添加你想解锁的域名...
    
    # 4. 兜底规则：其他没写在上面的所有普通网站，统统走面板的纯净直连 IP。
    # 这样你就既保留了“纯 hy2 节点”无痛过普通 CF 网站的优势，又拥有了解锁特殊网站的能力。
    - direct(all)
EOF
    echo "✅ 写入配置 server.yaml 成功（已强制关闭 QUIC 并开启域名分流）。"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    # 同样不屏蔽 curl 报错输出，超时则使用默认文本
    IP=$(curl --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（含防 IP 分裂修复）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 你的面板IP: $IP"
    echo "   🔌 面板监听端口: $SERVER_PORT"
    echo "   🔑 连接密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Proxy"
    echo ""
    echo "⚠️ 提醒：只有代码中指定的域名才会走 66.181.36.237 出站，其余网站保持纯 hy2 直连。"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
