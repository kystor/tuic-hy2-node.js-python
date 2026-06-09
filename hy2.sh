#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 自动化部署脚本（支持一键卸载 del + 自动放行防火墙 + 自动后台完全不屏蔽输出运行）
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
echo "Hysteria2 自动化部署与清理脚本"
echo "安装示例：bash hy2.sh 443"
echo "卸载示例：bash hy2.sh del"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 核心功能：一键卸载 ----------
uninstall_hy2() {
    echo "🗑️ 检测到 'del' 参数，开始执行深度卸载与清理..."
    
    # 1. 尝试提取原有配置中的端口号（为了清理防火墙）
    local old_port=""
    if [ -f "server.yaml" ]; then
        # 读取 server.yaml 中 listen 后面的端口数字
        old_port=$(grep -oP 'listen: ":\K\d+' server.yaml || true)
    fi

    # 2. 强行终止后台的 Hysteria2 进程
    echo "🛑 正在停止 Hysteria2 后台运行进程..."
    # 即使进程不存在也忽略报错，继续往下执行
    pkill -f "hysteria-linux" || echo "   未发现运行中的进程，跳过。"

    # 3. 撤销防火墙放行规则（做到不留痕迹）
    if [ -n "$old_port" ]; then
        echo "🛡️ 正在撤销防火墙放行规则 (端口: $old_port)..."
        if command -v iptables &> /dev/null; then
            # -D 代表 Delete (删除) 规则，2>/dev/null 屏蔽找不到规则时的报错
            iptables -D INPUT -p udp --dport "$old_port" -j ACCEPT 2>/dev/null || true
            iptables -D OUTPUT -p udp --sport "$old_port" -j ACCEPT 2>/dev/null || true
        fi
        if command -v ufw &> /dev/null; then
            ufw delete allow "$old_port"/udp &> /dev/null || true
        fi
    fi

    # 4. 彻底删除所有相关文件
    echo "🗑️ 正在删除核心程序及相关配置文件..."
    rm -f hysteria-linux-*
    rm -f server.yaml
    rm -f "$CERT_FILE" "$KEY_FILE"
    rm -f hy2_run.log
    
    echo "=========================================================================="
    echo "✅ 卸载圆满成功！"
    echo "所有核心程序、配置文件、自签证书、日志记录以及防火墙规则均已彻底清除。"
    echo "你的服务器目前已经恢复到安装前的清爽状态。"
    echo "=========================================================================="
}

# ---------- 检查参数并决定执行分支 ----------
# 如果传入的第一个参数是 del，则执行卸载并直接退出脚本
if [[ "${1:-}" == "del" ]]; then
    uninstall_hy2
    exit 0
fi

# 如果不是 del，说明用户是想要安装/运行。将参数视作端口号。
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 以下为原有的安装逻辑 ----------

# 检测架构
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

# 下载二进制
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

# 生成证书
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现已有的证书文件，直接使用 cert/key。"
        return
    fi
    echo "🔑 未发现证书，正在调用 openssl 生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# 写配置文件
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

acl:
  inline:
    - direct(all)
EOF
    echo "✅ 写入配置 server.yaml 成功。"
}

# 自动开放防火墙端口
open_firewall() {
    echo "🛡️ 正在尝试自动配置系统防火墙，放行 UDP 端口: $SERVER_PORT ..."
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p udp --dport "$SERVER_PORT" -j ACCEPT 2>&1
        iptables -I OUTPUT -p udp --sport "$SERVER_PORT" -j ACCEPT 2>&1
    fi
    if command -v ufw &> /dev/null; then
        ufw allow "$SERVER_PORT"/udp &> /dev/null
    fi
    echo "✅ 防火墙放行规则配置尝试完成。"
}

# 获取服务器 IP
get_server_ip() {
    IP=$(curl -s --max-time 10 https://api.ipify.org || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# 打印连接信息
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

# 主逻辑 (安装模式)
main() {
    pkill -f "${BIN_NAME}" || true
    download_binary
    ensure_cert
    write_config
    open_firewall
    
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    
    echo "🚀 正在使用 nohup 将 Hysteria2 送入系统后台默默运行..."
    nohup "$BIN_PATH" server -c server.yaml > hy2_run.log 2>&1 &
    
    sleep 1
    if ps -ef | grep -v grep | grep -q "${BIN_NAME}"; then
        echo "🟩 【成功】Hysteria2 已经在后台顺利启动！"
        echo "📊 实时查看运行日志: tail -f hy2_run.log"
        echo "💡 现在你可以安全地关闭这个 SSH 终端黑框了。"
    else
        echo "🟥 【错误】后台进程未能成功维持运行！"
        echo "🔍 请立刻运行命令查看日志: cat hy2_run.log"
    fi
}

# 因为最上面已经处理过 del 参数了，走到这里的只能是正常的端口号或者空参数
main "$@"
