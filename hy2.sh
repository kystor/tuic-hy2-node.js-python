#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 适用于超低内存环境（32-64MB）
# 本版本已修改：添加了全局出站 SOCKS5 代理 (66.181.36.237:25556)

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222         # 自适应端口
AUTH_PASSWORD="ieshare2025"   # 建议修改为复杂密码
CERT_FILE="cert.pem"
KEY_FILE="key.pem"
SNI="www.bing.com"
ALPN="h3"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（带出站代理）"
echo "支持命令行端口参数，如：bash hy2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
# 检查是否在启动命令中传入了端口号
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
# 自动检测系统的 CPU 架构，以决定下载哪个版本的 Hysteria2
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
# 下载主程序，保留了 curl 的输出，方便你观察下载进度和网络状态
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 正在从 Github 下载 Hysteria2 主程序: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并已赋予可执行权限: $BIN_PATH"
}

# ---------- 生成证书 ----------
# 生成自签名的 SSL 证书，保留 openssl 输出信息供排错使用
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现已有的证书文件，直接使用 cert/key。"
        return
    fi
    echo "🔑 未发现证书，正在调用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
# 生成 server.yaml，这里包含了你要求的出站代理 (Outbounds) 配置
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

# === 出站代理配置 (Outbounds) ===
# 定义了一个名为 custom_outbound 的代理出口
outbounds:
  - name: custom_outbound
    type: socks5
    socks5:
      addr: "66.181.36.237:25556"

# === 路由分流规则 (ACL) ===
# 让面板所有的网络请求 (all)，强制走上面的 custom_outbound 代理节点出站
acl:
  inline:
    - proxy(all, custom_outbound)
EOF
    echo "✅ 写入配置 server.yaml 成功。"
    echo "   配置详情: 端口=${SERVER_PORT}, SNI=${SNI}, 代理出口=66.181.36.237:25556"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    # 不屏蔽 curl 输出，如果网络超时会输出默认字样
    IP=$(curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（含自定义出站代理）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 你的面板IP: $IP"
    echo "   🔌 面板监听端口: $SERVER_PORT"
    echo "   🔑 连接密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Proxy"
    echo ""
    echo "⚠️ 提醒：客户端连上此节点后，实际访问网络的 IP 将变成 66.181.36.237"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
# 依次执行各步骤函数
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器..."
    # 启动进程，输出全部运行日志到控制台
    exec "$BIN_PATH" server -c server.yaml
}

# 将所有的命令行参数传递给 main 函数
main "$@"
