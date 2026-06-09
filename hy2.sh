#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（支持命令行端口参数 + 默认跳过证书验证）
# 适用于超低内存环境（32-64MB）
# 本版本已修改：添加了全局出站 SOCKS5 代理 (66.181.36.237:25556)

set -e # 遇到错误立刻停止脚本运行，防止产生连锁反应

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222         # 当用户不输入端口时，使用的默认端口
AUTH_PASSWORD="ieshare2025"   # 客户端连接所需的认证密码
CERT_FILE="cert.pem"       # 证书公钥文件名
KEY_FILE="key.pem"         # 证书私钥文件名
SNI="www.bing.com"         # 伪装域名（用于绕过防火墙探测）
ALPN="h3"                  # 应用层协议协商，指定为 HTTP/3 协议
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（带出站代理）"
echo "支持命令行端口参数，如：bash hy2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
# $# 代表传入参数的个数，$1 代表第一个参数
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
# 这一步是为了让脚本兼容不同的服务器（比如有的是 AMD/Intel 芯片，有的是 ARM 芯片）
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]') # 获取系统架构并全部转为小写
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
    # 检查当前目录是否已经有下载好的文件，如果有则跳过下载，节省时间
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 正在从 Github 下载 Hysteria2 主程序: $URL"
    # curl 不加 -s (静默模式)，这样能在屏幕上清晰看到下载进度条
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    
    # 下载完的程序默认是一块“普通石头”，必须用 chmod +x 赋予它“可执行”的权力
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并已赋予可执行权限: $BIN_PATH"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现已有的证书文件，直接使用 cert/key。"
        return
    fi
    echo "🔑 未发现证书，正在调用 openssl 生成自签证书（prime256v1）..."
    # 调用系统自带的 openssl 工具生成有效期 3650 天的私钥和公钥，保留输出以供排错
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
# 生成运行所需的 server.yaml 文件（核心逻辑都在这里）
write_config() {
# 使用 cat <<EOF 将中间的所有内容直接写入到 server.yaml 文件中
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
outbounds:
  - name: custom_outbound        # 【重点】定义了一个名字叫 custom_outbound 的代理出口
    type: socks5
    socks5:
      addr: "66.181.36.237:25556"

# === 路由分流规则 (ACL) ===
acl:
  inline:
    # 【修复完成】语法：直接写 出站名字(匹配范围)
    # 意思为：把所有的流量 (all) 都分配给名为 custom_outbound 的代理节点
    - custom_outbound(all)
EOF
    echo "✅ 写入配置 server.yaml 成功。"
    echo "   配置详情: 端口=${SERVER_PORT}, SNI=${SNI}, 代理出口=66.181.36.237:25556"
}

# ---------- 获取服务器 IP ----------
get_server_ip() {
    # 尝试访问 ipify 接口获取本机公网 IP。如果网络超时，默认返回一段提示文字
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
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    
    echo "🚀 启动 Hysteria2 服务器..."
    # 最终执行主程序并加载刚才写好的 server.yaml。
    # exec 命令会让 Hysteria 进程接管当前的终端，所以程序运行时产生的任何日志都会直接打印在屏幕上
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
