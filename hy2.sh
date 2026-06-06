#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 交互式部署脚本（对接落地代理 SOCKS5 出站）
# 用途：
#   客户端 -> VPS2(Hysteria2) -> 落地代理(本项目 SOCKS5) -> 当前 milivpn/VPNGate 出口 -> 目标网站
#
# 默认策略：
#   TCP 走落地代理 SOCKS5，UDP 直连 VPS2
#   这样更稳，适合“网页固定出口 IP，UDP 不受 SOCKS5 UDP 能力影响”的场景
#
# 可选策略：
#   MODE=all_proxy
#   尝试让 TCP/UDP 都走落地代理 SOCKS5。是否稳定取决于上游对 UDP 的支持情况。

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

LANDING_PROXY_HOST="${LANDING_PROXY_HOST:-${UPSTREAM_SOCKS_HOST:-}}"
LANDING_PROXY_PORT="${LANDING_PROXY_PORT:-${UPSTREAM_SOCKS_PORT:-7928}}"
LANDING_PROXY_USER="${LANDING_PROXY_USER:-${UPSTREAM_SOCKS_USER:-}}"
LANDING_PROXY_PASS="${LANDING_PROXY_PASS:-${UPSTREAM_SOCKS_PASS:-}}"

UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

USE_LANDING_PROXY="${USE_LANDING_PROXY:-auto}"
LANDING_PROXY_AUTH_ENABLED="${LANDING_PROXY_AUTH_ENABLED:-auto}"

# ---------- 终端样式 ----------
if [[ -t 1 ]]; then
    C_RESET="$(printf '\033[0m')"
    C_BOLD="$(printf '\033[1m')"
    C_DIM="$(printf '\033[2m')"
    C_BLUE="$(printf '\033[34m')"
    C_CYAN="$(printf '\033[36m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_RED="$(printf '\033[31m')"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_BLUE=""
    C_CYAN=""
    C_GREEN=""
    C_YELLOW=""
    C_RED=""
fi

hr() {
    printf '%s\n' "========================================================================"
}

print_banner() {
    hr
    printf '%b\n' "${C_BOLD}${C_CYAN}Hysteria2 交互式部署脚本${C_RESET}"
    printf '%b\n' "${C_DIM}链路: 客户端 -> VPS2(Hysteria2) -> 落地代理 SOCKS5 -> milivpn/VPNGate 出口${C_RESET}"
    printf '%b\n' "${C_DIM}默认模式: TCP 走落地代理，UDP 直连 VPS2${C_RESET}"
    hr
}

info() {
    printf '%b %s\n' "${C_BLUE}[信息]${C_RESET}" "$*"
}

success() {
    printf '%b %s\n' "${C_GREEN}[完成]${C_RESET}" "$*"
}

warn() {
    printf '%b %s\n' "${C_YELLOW}[提示]${C_RESET}" "$*"
}

error() {
    printf '%b %s\n' "${C_RED}[错误]${C_RESET}" "$*" >&2
}

# ---------- 帮助 ----------
usage() {
    cat <<'EOF'
用法：
  bash hy2.sh [监听端口] [落地代理_HOST] [落地代理_SOCKS5端口]

示例：
  bash hy2.sh
  bash hy2.sh 443
  bash hy2.sh 443 1.2.3.4 7928
  MODE=all_proxy bash hy2.sh 443 1.2.3.4 7928
  LANDING_PROXY_USER=user LANDING_PROXY_PASS=pass bash hy2.sh 443 1.2.3.4 7928

环境变量：
  MODE
    tcp_proxy_udp_direct   默认，TCP 走落地代理 SOCKS5，UDP 直连 VPS2
    all_proxy              尝试 TCP/UDP 都走落地代理 SOCKS5

  LANDING_PROXY_HOST       落地代理公网 IP 或域名
  LANDING_PROXY_PORT       落地代理 SOCKS5 端口，默认 7928
  LANDING_PROXY_USER       落地代理 SOCKS5 用户名，可留空
  LANDING_PROXY_PASS       落地代理 SOCKS5 密码，可留空

说明：
  1. VPS2 配的是落地代理的 SOCKS5 地址，不是当前 VPNGate 落地 IP。
  2. 以后想换出口 IP，只需要去落地代理的 milivpn 面板切节点。
  3. 脚本支持“参数优先、缺失项交互补全”。
EOF
}

# ---------- 基础函数 ----------
validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

is_yes() {
    case "${1:-}" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

read_with_default() {
    local prompt="$1"
    local default_value="${2:-}"
    local input

    if [[ -n "$default_value" ]]; then
        printf '%b' "${C_BOLD}${prompt}${C_RESET} ${C_DIM}[${default_value}]${C_RESET}: "
    else
        printf '%b' "${C_BOLD}${prompt}${C_RESET}: "
    fi
    IFS= read -r input || true

    if [[ -z "$input" ]]; then
        printf '%s' "$default_value"
    else
        printf '%s' "$input"
    fi
}

read_secret_with_default() {
    local prompt="$1"
    local default_value="${2:-}"
    local input

    if [[ -n "$default_value" ]]; then
        printf '%b' "${C_BOLD}${prompt}${C_RESET} ${C_DIM}[已存在，回车保持不变]${C_RESET}: "
    else
        printf '%b' "${C_BOLD}${prompt}${C_RESET}: "
    fi
    IFS= read -r -s input || true
    printf '\n'

    if [[ -z "$input" ]]; then
        printf '%s' "$default_value"
    else
        printf '%s' "$input"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default_choice="${2:-N}"
    local input

    while true; do
        printf '%b' "${C_BOLD}${prompt}${C_RESET} ${C_DIM}[y/N，默认 ${default_choice}]${C_RESET}: "
        IFS= read -r input || true
        input="${input:-$default_choice}"
        case "$input" in
            y|Y|yes|YES|Yes) return 0 ;;
            n|N|no|NO|No) return 1 ;;
            *) warn "请输入 y 或 n。" ;;
        esac
    done
}

ask_menu_mode() {
    local input
    while true; do
        printf '%b\n' "${C_BOLD}请选择分流模式${C_RESET}"
        printf '  1. TCP 走落地代理，UDP 直连 %b(推荐)%b\n' "${C_GREEN}" "${C_RESET}"
        printf '  2. TCP/UDP 都走落地代理 %b(依赖 UDP over SOCKS5 支持)%b\n' "${C_YELLOW}" "${C_RESET}"
        printf '%b' "${C_BOLD}请输入选项${C_RESET} ${C_DIM}[1]${C_RESET}: "
        IFS= read -r input || true
        input="${input:-1}"
        case "$input" in
            1)
                MODE="tcp_proxy_udp_direct"
                return 0
                ;;
            2)
                MODE="all_proxy"
                return 0
                ;;
            *)
                warn "请输入 1 或 2。"
                ;;
        esac
    done
}

ask_port() {
    local prompt="$1"
    local default_port="$2"
    local value

    while true; do
        value="$(read_with_default "$prompt" "$default_port")"
        if validate_port "$value"; then
            printf '%s' "$value"
            return 0
        fi
        warn "端口必须是 1-65535 之间的数字。"
    done
}

mode_description() {
    case "$MODE" in
        tcp_proxy_udp_direct) printf '%s' 'TCP 走落地代理 / UDP 直连' ;;
        all_proxy) printf '%s' 'TCP/UDP 都走落地代理' ;;
        *) printf '%s' "$MODE" ;;
    esac
}

print_summary() {
    hr
    printf '%b\n' "${C_BOLD}${C_CYAN}配置确认${C_RESET}"
    printf '%s\n' "Hysteria2 监听端口 : ${SERVER_PORT}"
    printf '%s\n' "Hysteria2 连接密码 : ${AUTH_PASSWORD}"
    printf '%s\n' "伪装 SNI           : ${SNI}"
    printf '%s\n' "ALPN               : ${ALPN}"
    if is_yes "$USE_LANDING_PROXY"; then
        printf '%s\n' "落地代理 SOCKS5    : ${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
        if is_yes "$LANDING_PROXY_AUTH_ENABLED"; then
            printf '%s\n' "落地代理认证       : 已启用"
            printf '%s\n' "落地代理账号       : ${LANDING_PROXY_USER}"
        else
            printf '%s\n' "落地代理认证       : 未启用"
        fi
    else
        printf '%s\n' "落地代理 SOCKS5    : 未使用"
    fi
    printf '%s\n' "分流模式           : $(mode_description)"
    hr
}

# ---------- 参数处理 ----------
parse_args() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ $# -ge 1 && -n "${1:-}" ]]; then
        SERVER_PORT="$1"
        info "已从命令行读取监听端口: ${SERVER_PORT}"
    else
        SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    fi

    if [[ $# -ge 2 && -n "${2:-}" ]]; then
        LANDING_PROXY_HOST="$2"
        USE_LANDING_PROXY="y"
        info "已从命令行读取落地代理地址: ${LANDING_PROXY_HOST}"
    fi

    if [[ $# -ge 3 && -n "${3:-}" ]]; then
        LANDING_PROXY_PORT="$3"
        info "已从命令行读取落地代理端口: ${LANDING_PROXY_PORT}"
    fi
}

normalize_defaults() {
    if [[ -n "${LANDING_PROXY_HOST}" && "${USE_LANDING_PROXY}" == "auto" ]]; then
        USE_LANDING_PROXY="y"
    fi

    if [[ -n "${LANDING_PROXY_USER}" || -n "${LANDING_PROXY_PASS}" ]]; then
        LANDING_PROXY_AUTH_ENABLED="y"
    elif [[ "${LANDING_PROXY_AUTH_ENABLED}" == "auto" ]]; then
        LANDING_PROXY_AUTH_ENABLED="n"
    fi

    if [[ "${USE_LANDING_PROXY}" == "auto" ]]; then
        USE_LANDING_PROXY="n"
    fi
}

validate_non_interactive_inputs() {
    if ! validate_port "${SERVER_PORT:-}"; then
        error "Hysteria2 监听端口无效: ${SERVER_PORT:-<空>}"
        exit 1
    fi

    if [[ -n "${LANDING_PROXY_HOST}" ]] && ! validate_port "${LANDING_PROXY_PORT:-}"; then
        error "落地代理 SOCKS5 端口无效: ${LANDING_PROXY_PORT:-<空>}"
        exit 1
    fi

    case "$MODE" in
        tcp_proxy_udp_direct|all_proxy) ;;
        *)
            error "MODE 无效: ${MODE}"
            error "可选值: tcp_proxy_udp_direct / all_proxy"
            exit 1
            ;;
    esac
}

# ---------- 交互配置 ----------
interactive_setup() {
    SERVER_PORT="$(ask_port "请输入 Hysteria2 监听端口" "${SERVER_PORT:-$DEFAULT_PORT}")"

    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        info "已检测到预设的落地代理配置，将继续确认和补全。"
    else
        if ask_yes_no "是否使用落地代理 SOCKS5 出站" "Y"; then
            USE_LANDING_PROXY="y"
        else
            USE_LANDING_PROXY="n"
        fi
    fi

    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        while [[ -z "$LANDING_PROXY_HOST" ]]; do
            LANDING_PROXY_HOST="$(read_with_default "请输入落地代理公网 IP 或域名" "${LANDING_PROXY_HOST:-}")"
            if [[ -z "$LANDING_PROXY_HOST" ]]; then
                warn "落地代理地址不能为空。"
            fi
        done

        LANDING_PROXY_PORT="$(ask_port "请输入落地代理 SOCKS5 端口" "${LANDING_PROXY_PORT:-7928}")"

        if [[ "${LANDING_PROXY_AUTH_ENABLED}" == "y" ]]; then
            info "已检测到落地代理认证配置，将继续确认。"
        else
            if ask_yes_no "落地代理 SOCKS5 是否需要账号密码认证" "N"; then
                LANDING_PROXY_AUTH_ENABLED="y"
            else
                LANDING_PROXY_AUTH_ENABLED="n"
            fi
        fi

        if [[ "${LANDING_PROXY_AUTH_ENABLED}" == "y" ]]; then
            while [[ -z "$LANDING_PROXY_USER" ]]; do
                LANDING_PROXY_USER="$(read_with_default "请输入落地代理 SOCKS5 用户名" "${LANDING_PROXY_USER:-}")"
                if [[ -z "$LANDING_PROXY_USER" ]]; then
                    warn "用户名不能为空。"
                fi
            done
            LANDING_PROXY_PASS="$(read_secret_with_default "请输入落地代理 SOCKS5 密码" "${LANDING_PROXY_PASS:-}")"
        else
            LANDING_PROXY_USER=""
            LANDING_PROXY_PASS=""
        fi
    else
        LANDING_PROXY_HOST=""
        LANDING_PROXY_PORT="7928"
        LANDING_PROXY_USER=""
        LANDING_PROXY_PASS=""
        LANDING_PROXY_AUTH_ENABLED="n"
    fi

    if [[ "${MODE}" != "tcp_proxy_udp_direct" && "${MODE}" != "all_proxy" ]]; then
        MODE="tcp_proxy_udp_direct"
    fi
    ask_menu_mode

    while true; do
        print_summary
        if ask_yes_no "是否确认以上配置并继续部署" "Y"; then
            break
        fi
        warn "将重新进入交互配置。"
        interactive_setup
        return 0
    done
}

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

detect_arch() {
    ARCH="$(arch_name)"
    if [[ -z "$ARCH" ]]; then
        error "无法识别 CPU 架构: $(uname -m)"
        exit 1
    fi
    BIN_NAME="hysteria-linux-${ARCH}"
    BIN_PATH="./${BIN_NAME}"
    info "检测到系统架构: ${ARCH}"
}

# ---------- 下载二进制 ----------
download_binary() {
    if [[ -f "$BIN_PATH" ]]; then
        success "Hysteria2 二进制已存在，跳过下载。"
        return
    fi

    local url
    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    info "开始下载 Hysteria2: ${url}"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"
    chmod +x "$BIN_PATH"
    success "下载完成并已设置可执行权限: ${BIN_PATH}"
}

# ---------- 生成证书 ----------
ensure_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        success "发现现有证书，直接复用 cert/key。"
        return
    fi

    info "未发现证书，正在生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    success "证书生成成功。"
}

# ---------- 配置片段 ----------
build_landing_proxy_auth_block() {
    if [[ "${USE_LANDING_PROXY}" == "y" && "${LANDING_PROXY_AUTH_ENABLED}" == "y" ]]; then
        cat <<EOF
      username: "${LANDING_PROXY_USER}"
      password: "${LANDING_PROXY_PASS}"
EOF
    fi
}

build_outbounds_block() {
    local auth_block=""
    auth_block="$(build_landing_proxy_auth_block)"

    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        cat <<EOF
outbounds:
  - name: landing_proxy
    type: socks5
    socks5:
      addr: "${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
${auth_block}
EOF
    fi
}

build_acl_block() {
    if [[ "${USE_LANDING_PROXY}" != "y" ]]; then
        cat <<'EOF'
acl:
  inline:
    - direct(all)
EOF
        return
    fi

    case "$MODE" in
        tcp_proxy_udp_direct)
            cat <<'EOF'
acl:
  inline:
    - landing_proxy(network:tcp)
    - direct(network:udp)
EOF
            ;;
        all_proxy)
            cat <<'EOF'
acl:
  inline:
    - landing_proxy(all)
EOF
            ;;
    esac
}

# ---------- 写配置文件 ----------
write_config() {
    local outbounds_block
    local acl_block
    outbounds_block="$(build_outbounds_block)"
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

${outbounds_block}

${acl_block}
EOF

    success "已写入配置文件: server.yaml"
    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        info "落地代理 SOCKS5: ${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
    else
        info "当前未使用落地代理，所有流量将直连。"
    fi
    info "分流模式: $(mode_description)"
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

    hr
    printf '%b\n' "${C_BOLD}${C_GREEN}部署完成${C_RESET}"
    printf '%s\n' "VPS2 公网 IP        : ${server_ip}"
    printf '%s\n' "Hysteria2 监听端口  : ${SERVER_PORT}"
    printf '%s\n' "Hysteria2 连接密码  : ${AUTH_PASSWORD}"
    printf '%s\n' "分流模式            : $(mode_description)"
    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        printf '%s\n' "落地代理 SOCKS5     : ${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
        if [[ "${LANDING_PROXY_AUTH_ENABLED}" == "y" ]]; then
            printf '%s\n' "落地代理认证        : 已启用"
        else
            printf '%s\n' "落地代理认证        : 未启用"
        fi
    else
        printf '%s\n' "落地代理 SOCKS5     : 未使用"
    fi
    hr
    printf '%b\n' "${C_BOLD}${C_CYAN}节点链接${C_RESET}"
    printf '%s\n' "hysteria2://${AUTH_PASSWORD}@${server_ip}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Landing-Proxy"
    hr
    printf '%b\n' "${C_BOLD}${C_CYAN}说明${C_RESET}"
    printf '%s\n' "1. 客户端实际连接的是 VPS2。"
    if [[ "${USE_LANDING_PROXY}" == "y" ]]; then
        printf '%s\n' "2. VPS2 会把流量转发到落地代理的本项目 SOCKS5。"
        printf '%s\n' "3. 真正显示的出口 IP 由落地代理当前 milivpn/VPNGate 节点决定。"
        printf '%s\n' "4. 以后想换落地 IP，只需要去落地代理切节点，不需要改 VPS2。"
    else
        printf '%s\n' "2. 当前未配置落地代理，流量将直接从 VPS2 出口。"
    fi
    if [[ "${MODE}" == "tcp_proxy_udp_direct" && "${USE_LANDING_PROXY}" == "y" ]]; then
        printf '%s\n' "5. 当前模式下 TCP 走落地代理，UDP 仍从 VPS2 直连。"
    elif [[ "${MODE}" == "all_proxy" && "${USE_LANDING_PROXY}" == "y" ]]; then
        printf '%s\n' "5. 当前模式尝试让 TCP/UDP 都走落地代理，UDP 稳定性取决于上游支持。"
    fi
    hr
}

# ---------- 主逻辑 ----------
main() {
    print_banner
    parse_args "$@"
    normalize_defaults
    validate_non_interactive_inputs
    interactive_setup
    detect_arch
    download_binary
    ensure_cert
    write_config

    local server_ip
    server_ip="$(get_server_ip)"
    print_connection_info "$server_ip"

    info "正在启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
