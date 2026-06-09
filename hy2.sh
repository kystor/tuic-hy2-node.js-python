#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 自动化部署脚本（已优化：自动放行防火墙 + 默认直连防止中转失效 + 自动后台完全不屏蔽输出运行）
# 适用于超低内存环境（32-64MB）

set -e # 遇到错误立刻停止脚本运行，防止产生连锁反应

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222          # 当用户不输入端口时，使用的默认端口
AUTH_PASSWORD="ieshare2025"   # 客户端连接所需的认证密码
CERT_FILE="cert.pem"        # 证书公钥文件名
KEY_FILE="key.pem"          # 证书私钥文件名
SNI="www.bing.com"          # 伪装域名（用于绕过防火墙探测）
ALPN="h3"                   # 应用层协议协商，指定为 HTTP/3 协议
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 自动化部署脚本（支持全自动后台运行）"
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
# 【改动】默认改回直接连接互联网(direct)，防止因为中转服务器失效导致整台节点瘫痪。
# 如果将来需要重新对接 66.181.36.237 代理，可以取消下方几行的注释：
# outbounds:
#   - name: custom_outbound
#     type: socks5
#     socks5:
#       addr: "66.181.36.237:25556"

# === 路由分流规则 (ACL) ===
acl:
  inline:
    # 默认让所有流量直连
    - direct(all)
    # 如果上方启用了 custom_outbound 代理，请把上面一行删掉，并取消下方注释：
    # - custom_outbound(all)
EOF
    echo "✅ 写入配置 server.yaml 成功。"
    echo "   配置详情: 端口=${SERVER_PORT}, SNI=${SNI}, 当前模式=直接出站(直连)"
}

# ---------- 自动开放防火墙端口 ----------
# 【新增功能】全自动尝试调用系统防火墙工具，放行对应的 UDP 端口，避免手动漏配
open_firewall() {
    echo "🛡️ 正在尝试自动配置系统防火墙，放行 UDP 端口: $SERVER_PORT ..."
    
    # 检查并配置 iptables 防火墙
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT 2>&1
        iptables -I OUTPUT -p udp --sport "$SERVER_PORT" -j ACCEPT 2>&1
    fi
    
    # 检查并配置 ufw 防火墙 (Ubuntu/Debian 常用)
    if command -v ufw &> /dev/null; then
        ufw allow "$SERVER_PORT"/udp &> /dev/null
    fi
    
    echo "✅ 防火墙放行规则配置尝试完成。"
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
    echo "🎉 Hysteria2 配置生成完毕！"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "    🌐 你的面板IP: $IP"
    echo "    🔌 面板监听端口: $SERVER_PORT"
    echo "    🔑 连接密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Proxy"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    # 先行清理可能存在的旧程序进程，防止端口冲突占用
    pkill -f "${BIN_NAME}" || true
    
    download_binary
    ensure_cert
    write_config
    open_firewall   # 执行新增的防火墙放行逻辑
    
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    
    echo "🚀 正在使用 nohup 将 Hysteria2 送入系统后台默默运行..."
    # 【核心改动】移除 exec，改用 nohup 配合 & 进行后台不挂断运行
    # 2>&1 确保子进程的所有标准输出和错误输出都完整保存到 hy2_run.log 中，绝不隐藏屏蔽
    nohup "$BIN_PATH" server -c server.yaml > hy2_run.log 2>&1 &
    
    # 稍微等待 1 秒钟，让子进程飞一会儿，然后检查它是否成功存活
    sleep 1
    if ps -ef | grep -v grep | grep -q "${BIN_NAME}"; then
        echo "🟩 【成功】Hysteria2 已经在后台顺利启动！"
        echo "📊 你可以使用此命令实时查看子进程的完整输出日志: tail -f hy2_run.log"
        echo "🛑 如果以后需要彻底停止该节点服务，请运行命令: pkill -f hysteria"
        echo "💡 现在你可以安全地关闭这个 SSH 终端黑框了，后台程序不会受到任何影响。"
    else
        echo "🟥 【错误】后台进程未能成功维持运行！"
        echo "🔍 请立刻运行命令查看日志中的子进程报错输出: cat hy2_run.log"
    fi
}

main "$@"
