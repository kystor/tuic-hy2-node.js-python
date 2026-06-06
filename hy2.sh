#!/usr/bin/env bash

set -euo pipefail

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.6.5}"
DEFAULT_PORT="${DEFAULT_PORT:-22222}"
AUTH_PASSWORD="${AUTH_PASSWORD:-ieshare2025}"
CERT_FILE="${CERT_FILE:-cert.pem}"
KEY_FILE="${KEY_FILE:-key.pem}"
SNI="${SNI:-www.bing.com}"
ALPN="${ALPN:-h3}"
UP_BANDWIDTH="${UP_BANDWIDTH:-200mbps}"
DOWN_BANDWIDTH="${DOWN_BANDWIDTH:-200mbps}"

SERVER_PORT="${SERVER_PORT:-}"
MODE="${MODE:-tcp_proxy_udp_direct}"
LANDING_PROXY_HOST="${LANDING_PROXY_HOST:-${UPSTREAM_SOCKS_HOST:-}}"
LANDING_PROXY_PORT="${LANDING_PROXY_PORT:-${UPSTREAM_SOCKS_PORT:-7928}}"
LANDING_PROXY_USER="${LANDING_PROXY_USER:-${UPSTREAM_SOCKS_USER:-}}"
LANDING_PROXY_PASS="${LANDING_PROXY_PASS:-${UPSTREAM_SOCKS_PASS:-}}"
USE_LANDING_PROXY="${USE_LANDING_PROXY:-auto}"
LANDING_PROXY_AUTH_ENABLED="${LANDING_PROXY_AUTH_ENABLED:-auto}"

ACTION="install"
BIN_PATH=""

line() {
    printf '%s\n' "========================================================================"
}

info() {
    printf '[INFO] %s\n' "$*"
}

ok() {
    printf '[OK] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*"
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
用法：
  bash hy2.sh
  bash hy2.sh [监听端口]
  bash hy2.sh [监听端口] [落地代理_HOST] [落地代理_SOCKS5端口]
  bash hy2.sh --uninstall
  bash hy2.sh del

示例：
  bash hy2.sh
  bash hy2.sh 443
  bash hy2.sh 443 1.2.3.4 7928
  MODE=all_proxy bash hy2.sh 443 1.2.3.4 7928
  LANDING_PROXY_USER=user LANDING_PROXY_PASS=pass bash hy2.sh 443 1.2.3.4 7928
  bash hy2.sh --uninstall
  bash hy2.sh del

说明：
  1. VPS2 配的是“落地代理”的 SOCKS5 地址，不是当前落地 IP。
  2. 想换出口 IP，只需要去落地代理的 milivpn/VPNGate 切节点。
  3. 默认模式是 TCP 走落地代理、UDP 直连 VPS2。
  4. `del` 和 `--uninstall` 都表示卸载，只删除本脚本生成的 Hysteria2 文件，不删除当前项目源码。
EOF
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

read_text() {
    local prompt="$1"
    local default_value="${2:-}"
    local value

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " value || true
        REPLY="${value:-$default_value}"
    else
        read -r -p "$prompt: " value || true
        REPLY="$value"
    fi
}

read_secret() {
    local prompt="$1"
    local default_value="${2:-}"
    local value

    if [[ -n "$default_value" ]]; then
        read -r -s -p "$prompt [已有值，回车保持]: " value || true
        printf '\n'
        REPLY="${value:-$default_value}"
    else
        read -r -s -p "$prompt: " value || true
        printf '\n'
        REPLY="$value"
    fi
}

read_yes_no() {
    local prompt="$1"
    local default_value="${2:-y}"
    local value
    local hint

    if [[ "$default_value" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi

    while true; do
        read -r -p "$prompt [$hint]: " value || true
        value="${value:-$default_value}"
        case "$value" in
            y|Y|yes|YES|Yes)
                REPLY="y"
                return 0
                ;;
            n|N|no|NO|No)
                REPLY="n"
                return 0
                ;;
            *)
                warn "请输入 y 或 n。"
                ;;
        esac
    done
}

ask_port() {
    local prompt="$1"
    local default_value="$2"

    while true; do
        read_text "$prompt" "$default_value"
        if validate_port "$REPLY"; then
            return 0
        fi
        warn "端口必须是 1-65535 之间的数字。"
    done
}

choose_mode() {
    local value

    while true; do
        printf '%s\n' "请选择分流模式："
        printf '%s\n' "1. TCP 走落地代理，UDP 直连（推荐）"
        printf '%s\n' "2. TCP/UDP 都走落地代理"
        read -r -p "请输入选项 [1]: " value || true
        value="${value:-1}"
        case "$value" in
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

mode_text() {
    case "$MODE" in
        tcp_proxy_udp_direct) printf '%s' 'TCP 走落地代理 / UDP 直连' ;;
        all_proxy) printf '%s' 'TCP/UDP 都走落地代理' ;;
        direct) printf '%s' '全部直连 VPS2' ;;
        *) printf '%s' "$MODE" ;;
    esac
}

list_generated_files() {
    printf '%s\n' "./server.yaml"
    printf '%s\n' "./${CERT_FILE}"
    printf '%s\n' "./${KEY_FILE}"
    printf '%s\n' "./hysteria-linux-amd64"
    printf '%s\n' "./hysteria-linux-arm64"
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --uninstall|del|uninstall|remove|rm)
                ACTION="uninstall"
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                die "不支持的参数: $1"
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [[ ${#positional[@]} -ge 1 ]]; then
        SERVER_PORT="${positional[0]}"
    fi
    if [[ ${#positional[@]} -ge 2 ]]; then
        LANDING_PROXY_HOST="${positional[1]}"
        USE_LANDING_PROXY="y"
    fi
    if [[ ${#positional[@]} -ge 3 ]]; then
        LANDING_PROXY_PORT="${positional[2]}"
    fi
    if [[ ${#positional[@]} -gt 3 ]]; then
        die "参数过多。使用 --help 查看用法。"
    fi
}

normalize_config() {
    [[ -n "$SERVER_PORT" ]] || SERVER_PORT="$DEFAULT_PORT"

    if [[ "$USE_LANDING_PROXY" == "auto" ]]; then
        if [[ -n "$LANDING_PROXY_HOST" ]]; then
            USE_LANDING_PROXY="y"
        else
            USE_LANDING_PROXY="n"
        fi
    fi

    if [[ "$LANDING_PROXY_AUTH_ENABLED" == "auto" ]]; then
        if [[ -n "$LANDING_PROXY_USER" || -n "$LANDING_PROXY_PASS" ]]; then
            LANDING_PROXY_AUTH_ENABLED="y"
        else
            LANDING_PROXY_AUTH_ENABLED="n"
        fi
    fi

    if [[ "$USE_LANDING_PROXY" != "y" ]]; then
        MODE="direct"
        LANDING_PROXY_HOST=""
        LANDING_PROXY_PORT="7928"
        LANDING_PROXY_USER=""
        LANDING_PROXY_PASS=""
        LANDING_PROXY_AUTH_ENABLED="n"
    fi
}

interactive_config() {
    local default_use_proxy="y"
    local default_auth="n"

    ask_port "请输入 Hysteria2 监听端口" "$SERVER_PORT"
    SERVER_PORT="$REPLY"

    if [[ "$USE_LANDING_PROXY" == "n" ]]; then
        default_use_proxy="n"
    fi
    read_yes_no "是否使用落地代理 SOCKS5 出站" "$default_use_proxy"
    USE_LANDING_PROXY="$REPLY"

    if [[ "$USE_LANDING_PROXY" == "y" ]]; then
        while true; do
            read_text "请输入落地代理公网 IP 或域名" "$LANDING_PROXY_HOST"
            LANDING_PROXY_HOST="$REPLY"
            [[ -n "$LANDING_PROXY_HOST" ]] && break
            warn "落地代理地址不能为空。"
        done

        ask_port "请输入落地代理 SOCKS5 端口" "$LANDING_PROXY_PORT"
        LANDING_PROXY_PORT="$REPLY"

        if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
            default_auth="y"
        fi
        read_yes_no "落地代理 SOCKS5 是否需要账号密码认证" "$default_auth"
        LANDING_PROXY_AUTH_ENABLED="$REPLY"

        if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
            while true; do
                read_text "请输入落地代理 SOCKS5 用户名" "$LANDING_PROXY_USER"
                LANDING_PROXY_USER="$REPLY"
                [[ -n "$LANDING_PROXY_USER" ]] && break
                warn "用户名不能为空。"
            done

            while true; do
                read_secret "请输入落地代理 SOCKS5 密码" "$LANDING_PROXY_PASS"
                LANDING_PROXY_PASS="$REPLY"
                [[ -n "$LANDING_PROXY_PASS" ]] && break
                warn "密码不能为空。"
            done
        else
            LANDING_PROXY_USER=""
            LANDING_PROXY_PASS=""
        fi

        choose_mode
    else
        MODE="direct"
        LANDING_PROXY_HOST=""
        LANDING_PROXY_PORT="7928"
        LANDING_PROXY_USER=""
        LANDING_PROXY_PASS=""
        LANDING_PROXY_AUTH_ENABLED="n"
    fi
}

validate_config() {
    validate_port "$SERVER_PORT" || die "Hysteria2 监听端口无效: $SERVER_PORT"

    case "$USE_LANDING_PROXY" in
        y|n) ;;
        *) die "USE_LANDING_PROXY 只能是 y 或 n" ;;
    esac

    if [[ "$USE_LANDING_PROXY" == "y" ]]; then
        [[ -n "$LANDING_PROXY_HOST" ]] || die "已启用落地代理，但地址为空。"
        validate_port "$LANDING_PROXY_PORT" || die "落地代理 SOCKS5 端口无效: $LANDING_PROXY_PORT"
        case "$MODE" in
            tcp_proxy_udp_direct|all_proxy) ;;
            *) die "MODE 无效: $MODE" ;;
        esac

        case "$LANDING_PROXY_AUTH_ENABLED" in
            y|n) ;;
            *) die "LANDING_PROXY_AUTH_ENABLED 只能是 y 或 n" ;;
        esac

        if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
            [[ -n "$LANDING_PROXY_USER" ]] || die "已启用落地代理认证，但用户名为空。"
            [[ -n "$LANDING_PROXY_PASS" ]] || die "已启用落地代理认证，但密码为空。"
        fi
    else
        MODE="direct"
    fi
}

print_summary() {
    line
    printf '%s\n' "配置确认"
    printf '%s\n' "Hysteria2 监听端口 : $SERVER_PORT"
    printf '%s\n' "Hysteria2 连接密码 : $AUTH_PASSWORD"
    printf '%s\n' "伪装 SNI           : $SNI"
    printf '%s\n' "ALPN               : $ALPN"
    printf '%s\n' "分流模式           : $(mode_text)"
    if [[ "$USE_LANDING_PROXY" == "y" ]]; then
        printf '%s\n' "落地代理 SOCKS5    : ${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
        if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
            printf '%s\n' "落地代理认证       : 已启用"
            printf '%s\n' "落地代理账号       : $LANDING_PROXY_USER"
        else
            printf '%s\n' "落地代理认证       : 未启用"
        fi
    else
        printf '%s\n' "落地代理 SOCKS5    : 未使用"
    fi
    line
}

confirm_or_exit() {
    read_yes_no "是否确认以上配置并继续部署" "y"
    [[ "$REPLY" == "y" ]] || exit 0
}

arch_name() {
    local machine
    machine="$(uname -m | tr '[:upper:]' '[:lower:]')"
    case "$machine" in
        *arm64*|*aarch64*) printf '%s' 'arm64' ;;
        *x86_64*|*amd64*) printf '%s' 'amd64' ;;
        *) printf '%s' '' ;;
    esac
}

download_binary() {
    local arch
    local bin_name
    local url

    arch="$(arch_name)"
    [[ -n "$arch" ]] || die "无法识别 CPU 架构: $(uname -m)"

    bin_name="hysteria-linux-${arch}"
    BIN_PATH="./${bin_name}"

    if [[ -f "$BIN_PATH" ]]; then
        ok "Hysteria2 二进制已存在，跳过下载。"
        return 0
    fi

    url="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${bin_name}"
    info "开始下载: $url"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$url"
    chmod +x "$BIN_PATH"
    ok "下载完成: $BIN_PATH"
}

ensure_cert() {
    if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
        ok "发现现有证书，直接复用。"
        return 0
    fi

    info "未发现证书，正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    ok "证书生成成功。"
}

write_config() {
    {
        cat <<EOF
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
EOF

        if [[ "$USE_LANDING_PROXY" == "y" ]]; then
            cat <<EOF

outbounds:
  - name: landing_proxy
    type: socks5
    socks5:
      addr: "${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
EOF

            if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
                cat <<EOF
      username: "${LANDING_PROXY_USER}"
      password: "${LANDING_PROXY_PASS}"
EOF
            fi

            if [[ "$MODE" == "tcp_proxy_udp_direct" ]]; then
                cat <<'EOF'

acl:
  inline:
    - landing_proxy(network:tcp)
    - direct(network:udp)
EOF
            else
                cat <<'EOF'

acl:
  inline:
    - landing_proxy(all)
EOF
            fi
        else
            cat <<'EOF'

acl:
  inline:
    - direct(all)
EOF
        fi
    } > server.yaml

    ok "已写入配置文件: server.yaml"
}

get_server_ip() {
    curl --max-time 10 https://api.ipify.org 2>/dev/null || printf '%s' 'YOUR_VPS2_IP'
}

print_connection_info() {
    local server_ip="$1"

    line
    printf '%s\n' "部署完成"
    printf '%s\n' "VPS2 公网 IP        : $server_ip"
    printf '%s\n' "Hysteria2 监听端口  : $SERVER_PORT"
    printf '%s\n' "Hysteria2 连接密码  : $AUTH_PASSWORD"
    printf '%s\n' "分流模式            : $(mode_text)"
    if [[ "$USE_LANDING_PROXY" == "y" ]]; then
        printf '%s\n' "落地代理 SOCKS5     : ${LANDING_PROXY_HOST}:${LANDING_PROXY_PORT}"
        if [[ "$LANDING_PROXY_AUTH_ENABLED" == "y" ]]; then
            printf '%s\n' "落地代理认证        : 已启用"
        else
            printf '%s\n' "落地代理认证        : 未启用"
        fi
    else
        printf '%s\n' "落地代理 SOCKS5     : 未使用"
    fi
    line
    printf '%s\n' "节点链接"
    printf '%s\n' "hysteria2://${AUTH_PASSWORD}@${server_ip}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Landing-Proxy"
    line
    printf '%s\n' "说明"
    printf '%s\n' "1. 客户端实际连接的是 VPS2。"
    if [[ "$USE_LANDING_PROXY" == "y" ]]; then
        printf '%s\n' "2. VPS2 会把流量转发到落地代理的 SOCKS5。"
        printf '%s\n' "3. 真正显示的出口 IP 由落地代理当前 milivpn/VPNGate 节点决定。"
        printf '%s\n' "4. 想换落地 IP，只需要去落地代理切节点，不需要改 VPS2。"
        if [[ "$MODE" == "tcp_proxy_udp_direct" ]]; then
            printf '%s\n' "5. 当前模式下 TCP 走落地代理，UDP 仍从 VPS2 直连。"
        else
            printf '%s\n' "5. 当前模式尝试让 TCP/UDP 都走落地代理，UDP 稳定性取决于上游支持。"
        fi
    else
        printf '%s\n' "2. 当前未配置落地代理，流量将直接从 VPS2 出口。"
    fi
    line
}

uninstall_files() {
    local file

    line
    printf '%s\n' "将删除以下文件："
    while IFS= read -r file; do
        printf '  - %s\n' "$file"
    done < <(list_generated_files)
    printf '%s\n' "不会删除当前项目源码。"
    line

    read_yes_no "是否确认卸载" "n"
    [[ "$REPLY" == "y" ]] || exit 0

    while IFS= read -r file; do
        if [[ -e "$file" ]]; then
            rm -f -- "$file"
            ok "已删除: $file"
        else
            info "文件不存在，跳过: $file"
        fi
    done < <(list_generated_files)

    line
    ok "卸载完成。"
    line
}

main() {
    line
    printf '%s\n' "Hysteria2 部署脚本"
    printf '%s\n' "链路: 客户端 -> VPS2(Hysteria2) -> 落地代理 SOCKS5 -> milivpn/VPNGate 出口"
    line

    parse_args "$@"

    if [[ "$ACTION" == "uninstall" ]]; then
        uninstall_files
        exit 0
    fi

    normalize_config

    if [[ -t 0 ]]; then
        interactive_config
    fi

    validate_config

    if [[ -t 0 ]]; then
        print_summary
        confirm_or_exit
    fi

    download_binary
    ensure_cert
    write_config

    SERVER_IP="$(get_server_ip)"
    print_connection_info "$SERVER_IP"

    info "正在启动 Hysteria2 服务器..."
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
