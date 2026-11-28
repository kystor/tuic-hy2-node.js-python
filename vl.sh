#!/usr/bin/env bash

# ============================================================
# VLESS + Cloudflare CDN 管理脚本
#
# 核心：sing-box
# 协议：VLESS
# 传输：WebSocket
# TLS：Let's Encrypt
# CDN：Cloudflare 免费 CDN
#
# 安装目录：/opt/vless
# 快捷命令：vl
#
# 支持：
# Debian / Ubuntu
# AMD64 / ARM64
#
# ============================================================

set -o pipefail

# -------------------- 基础配置 --------------------

VERSION="1.0.0"

BASE_DIR="/opt/vless"
BIN_DIR="$BASE_DIR/bin"
CONFIG_DIR="$BASE_DIR/config"
CERT_DIR="$BASE_DIR/cert"
DATA_DIR="$BASE_DIR/data"
LOG_DIR="$BASE_DIR/logs"
SCRIPT_DIR="$BASE_DIR/script"
ACME_DIR="$BASE_DIR/acme"

CONFIG_FILE="$CONFIG_DIR/config.json"
NODE_FILE="$DATA_DIR/nodes.db"

CERT_FILE="$CERT_DIR/cert.pem"
KEY_FILE="$CERT_DIR/key.pem"

SERVICE_NAME="vless"
SERVICE_FILE="/etc/systemd/system/vless.service"

SCRIPT_FILE="$SCRIPT_DIR/vl.sh"
SHORTCUT="/usr/local/bin/vl"

ACME="$ACME_DIR/acme.sh"

# 修改为你自己的 GitHub 仓库地址后，
# 才能启用在线更新脚本功能。
SCRIPT_URL=""

DOMAIN=""
WS_PATH=""

# -------------------- 颜色配置 --------------------

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

# -------------------- 基础函数 --------------------

msg() {
    echo -e "${GREEN}[信息]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[警告]${RESET} $1"
}

err() {
    echo -e "${RED}[错误]${RESET} $1"
}

pause() {
    echo
    read -r -p "按回车键继续..."
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "请使用 root 用户运行脚本。"
        exit 1
    fi
}

# -------------------- 初始化目录 --------------------

init_dirs() {

    mkdir -p \
        "$BIN_DIR" \
        "$CONFIG_DIR" \
        "$CERT_DIR" \
        "$DATA_DIR" \
        "$LOG_DIR" \
        "$SCRIPT_DIR"

    touch "$NODE_FILE"

    chmod 700 "$BASE_DIR"
    chmod 700 "$CERT_DIR"

}

# -------------------- 安装依赖 --------------------

install_dependencies() {

    msg "检查系统依赖..."

    if command -v apt-get >/dev/null 2>&1; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update -y

        apt-get install -y \
            curl \
            wget \
            tar \
            gzip \
            openssl \
            ca-certificates \
            cron \
            iproute2

    else

        err "目前只支持 Debian / Ubuntu。"
        return 1

    fi

}

# -------------------- 检测 CPU 架构 --------------------

detect_arch() {

    ARCH="$(uname -m)"

    case "$ARCH" in

        x86_64)
            ARCH="amd64"
            ;;

        aarch64|arm64)
            ARCH="arm64"
            ;;

        *)
            err "不支持的 CPU 架构：$ARCH"
            return 1
            ;;

    esac

    msg "CPU 架构：$ARCH"

}

# -------------------- 下载 sing-box --------------------

install_singbox() {

    msg "正在获取 sing-box 最新稳定版本..."

    local API_URL="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

    local RELEASE_JSON

    RELEASE_JSON=$(curl -fsSL \
        --retry 3 \
        -H "User-Agent: VLESS-Manager" \
        "$API_URL") || {

        err "获取 sing-box 版本失败。"
        return 1

    }

    local TAG

    TAG=$(echo "$RELEASE_JSON" |
        grep -m1 '"tag_name"' |
        sed -E 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/')

    if [ -z "$TAG" ]; then

        err "无法识别 sing-box 版本。"
        return 1

    fi

    local VER="${TAG#v}"

    local URL="https://github.com/SagerNet/sing-box/releases/download/${TAG}/sing-box-${VER}-linux-${ARCH}.tar.gz"

    local TMP_DIR

    TMP_DIR=$(mktemp -d)

    msg "下载 sing-box $TAG ..."

    if ! curl -fL --retry 3 "$URL" \
        -o "$TMP_DIR/sing-box.tar.gz"; then

        rm -rf "$TMP_DIR"

        err "sing-box 下载失败。"
        return 1

    fi

    tar -xzf "$TMP_DIR/sing-box.tar.gz" \
        -C "$TMP_DIR" || {

        rm -rf "$TMP_DIR"
        err "解压失败。"
        return 1

    }

    local CORE

    CORE=$(find "$TMP_DIR" \
        -type f \
        -name sing-box \
        | head -n 1)

    if [ -z "$CORE" ]; then

        rm -rf "$TMP_DIR"

        err "未找到 sing-box 可执行文件。"
        return 1

    fi

    install -m 755 "$CORE" "$BIN_DIR/sing-box"

    rm -rf "$TMP_DIR"

    "$BIN_DIR/sing-box" version

    msg "sing-box 安装完成。"

}

# -------------------- 安装 acme.sh --------------------

install_acme() {

    if [ -x "$ACME" ]; then

        msg "检测到已有 acme.sh，跳过安装。"
        return 0

    fi

    msg "正在安装 acme.sh..."

    mkdir -p "$ACME_DIR"

    curl -fsSL \
        https://get.acme.sh \
        -o /tmp/acme-install.sh || {

        err "下载 acme.sh 失败。"
        return 1

    }

    sh /tmp/acme-install.sh \
        --home "$ACME_DIR" \
        --config-home "$ACME_DIR/data" \
        --accountemail "${EMAIL:-}" || {

        err "acme.sh 安装失败。"
        return 1

    }

    rm -f /tmp/acme-install.sh

    if [ ! -x "$ACME" ]; then

        err "acme.sh 可执行文件不存在。"
        return 1

    fi

    "$ACME" --set-default-ca --server letsencrypt

    msg "acme.sh 安装完成。"

}

# -------------------- 获取域名 --------------------

input_domain() {

    echo
    echo "请输入已经接入 Cloudflare 的域名。"
    echo
    echo "例如：cdn.example.com"
    echo

    read -r -p "域名: " DOMAIN

    DOMAIN=$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]')

    if [[ ! "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] ||
       [[ "$DOMAIN" != *.* ]] ||
       [[ "$DOMAIN" == *..* ]]; then

        err "域名格式不正确。"
        return 1

    fi

    if [ -f "$CONFIG_FILE" ]; then

        warn "检测到已有配置。"
        warn "修改域名需要重新申请证书。"

    fi

}

# -------------------- 生成 WebSocket 路径 --------------------

generate_path() {

    local RANDOM_PATH

    RANDOM_PATH=$(openssl rand -hex 12)

    WS_PATH="/vless/$RANDOM_PATH"

    msg "WebSocket 路径：$WS_PATH"

}

# -------------------- 检查端口 --------------------

check_port() {

    local PORT="$1"

    if ss -lntH "sport = :$PORT" 2>/dev/null | grep -q .; then

        err "TCP $PORT 端口已经被占用。"

        ss -lntp "sport = :$PORT"

        return 1

    fi

}

# -------------------- 配置防火墙 --------------------

configure_firewall() {

    if command -v ufw >/dev/null 2>&1; then

        if ufw status | grep -q "Status: active"; then

            msg "检测到 UFW 已启用，开放必要端口。"

            ufw allow 80/tcp
            ufw allow 443/tcp

        fi

    fi

    warn "如果 VPS 提供商有独立安全组，也需要开放 TCP 80、443。"

}

# -------------------- 申请 Let's Encrypt 证书 --------------------

issue_certificate() {

    msg "准备申请 Let's Encrypt 证书..."

    if [ ! -x "$ACME" ]; then

        err "acme.sh 尚未安装。"
        return 1

    fi

    # HTTP-01 验证需要使用 TCP 80。
    # Cloudflare 橙色云必须能够正常回源。

    check_port 80 || return 1

    msg "使用 HTTP-01 验证方式申请证书。"

    "$ACME" \
        --issue \
        --standalone \
        --httpport 80 \
        -d "$DOMAIN" \
        --keylength ec-256 \
        --server letsencrypt || {

        err "证书申请失败。"
        warn "请检查域名 DNS、Cloudflare 代理及 TCP 80 端口。"

        return 1

    }

    msg "证书申请成功。"

    mkdir -p "$CERT_DIR"

    # 将证书安装到项目目录。
    # 后续自动续期时会重新复制证书。

    "$ACME" \
        --install-cert \
        -d "$DOMAIN" \
        --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "systemctl restart vless.service >/dev/null 2>&1 || true" || {

        err "证书安装失败。"
        return 1

    }

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"

    msg "Let's Encrypt 证书配置完成。"

}

# -------------------- 生成 UUID --------------------

generate_uuid() {

    if command -v uuidgen >/dev/null 2>&1; then

        uuidgen | tr '[:upper:]' '[:lower:]'

    else

        cat /proc/sys/kernel/random/uuid

    fi

}

# -------------------- 创建默认节点 --------------------

create_default_node() {

    if [ -s "$NODE_FILE" ]; then

        return 0

    fi

    local UUID

    UUID=$(generate_uuid)

    echo "$UUID|default" >> "$NODE_FILE"

    msg "已创建默认节点。"

}

# -------------------- 生成 sing-box 配置 --------------------

build_config() {

    msg "正在生成 sing-box 配置..."

    if [ ! -f "$CERT_FILE" ] || [ ! -f "$KEY_FILE" ]; then

        err "证书文件不存在。"
        return 1

    fi

    if [ ! -s "$NODE_FILE" ]; then

        err "节点列表为空。"
        return 1

    fi

    local FIRST=1

    {
        cat <<EOF
{
    "log": {
        "level": "info",
        "timestamp": true
    },

    "inbounds": [
        {
            "type": "vless",
            "tag": "vless-in",
            "listen": "::",
            "listen_port": 443,

            "users": [
EOF

        while IFS='|' read -r UUID NAME; do

            [ -z "$UUID" ] && continue

            if [ "$FIRST" -eq 0 ]; then

                printf ",\n"

            fi

            printf '                {"uuid":"%s"}' "$UUID"

            FIRST=0

        done < "$NODE_FILE"

        cat <<EOF

            ],

            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "certificate_path": "$CERT_FILE",
                "key_path": "$KEY_FILE"
            },

            "transport": {
                "type": "ws",
                "path": "$WS_PATH"
            }
        }
    ],

    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        }
    ],

    "route": {
        "final": "direct"
    }
}
EOF

    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"

    # 检查 JSON 和 sing-box 配置是否合法。

    "$BIN_DIR/sing-box" check \
        -c "$CONFIG_FILE" || {

        err "sing-box 配置检查失败。"
        return 1

    }

    msg "配置生成成功。"

}

# -------------------- 创建 systemd 服务 --------------------

create_service() {

    msg "创建 systemd 服务..."

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VLESS Cloudflare CDN Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple

User=root
WorkingDirectory=$BASE_DIR

ExecStart=$BIN_DIR/sing-box run -c $CONFIG_FILE

Restart=on-failure
RestartSec=5

LimitNOFILE=1048576

NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload

    systemctl enable vless.service

    systemctl restart vless.service

    sleep 2

    if ! systemctl is-active --quiet vless.service; then

        err "VLESS 服务启动失败。"

        journalctl -u vless.service -n 30 --no-pager

        return 1

    fi

    msg "VLESS 服务启动成功。"

}

# -------------------- 安装快捷命令 --------------------

install_shortcut() {

    cat > "$SHORTCUT" <<EOF
#!/usr/bin/env bash
exec bash "$SCRIPT_FILE" "\$@"
EOF

    chmod +x "$SHORTCUT"

    msg "快捷命令安装成功：vl"

}

# -------------------- URI 编码路径 --------------------

encode_path() {

    local VALUE="$1"

    VALUE="${VALUE//\//%2F}"

    echo "$VALUE"

}

# -------------------- 生成节点链接 --------------------

generate_link() {

    local UUID="$1"
    local NAME="$2"

    local ENCODED_PATH

    ENCODED_PATH=$(encode_path "$WS_PATH")

    echo
    echo "节点名称：$NAME"
    echo
    echo "vless://$UUID@$DOMAIN:443?encryption=none&security=tls&sni=$DOMAIN&type=ws&host=$DOMAIN&path=$ENCODED_PATH#$NAME"
    echo

}

# -------------------- 显示节点 --------------------

show_nodes() {

    if [ ! -f "$NODE_FILE" ] || [ ! -s "$NODE_FILE" ]; then

        warn "目前没有节点。"
        return

    fi

    echo
    echo "================ VLESS 节点列表 ================"
    echo

    local INDEX=0

    while IFS='|' read -r UUID NAME; do

        [ -z "$UUID" ] && continue

        INDEX=$((INDEX + 1))

        echo "[$INDEX] $NAME"
        echo "UUID：$UUID"

        generate_link "$UUID" "$NAME"

        echo "------------------------------------------------"

    done < "$NODE_FILE"

    echo "节点数量：$INDEX"

}

# -------------------- 添加节点 --------------------

add_node() {

    echo
    read -r -p "请输入节点名称: " NAME

    NAME=$(echo "$NAME" | tr -cd 'A-Za-z0-9._-')

    if [ -z "$NAME" ]; then

        err "节点名称不能为空。"
        return

    fi

    if grep -q "|$NAME$" "$NODE_FILE"; then

        err "节点名称已经存在。"
        return

    fi

    local UUID

    UUID=$(generate_uuid)

    echo "$UUID|$NAME" >> "$NODE_FILE"

    if ! build_config; then

        sed -i "\|$UUID|d" "$NODE_FILE"

        return 1

    fi

    if ! create_service; then

        warn "配置已经保存，但服务启动失败。"

        return 1

    fi

    msg "节点创建成功。"

    generate_link "$UUID" "$NAME"

}

# -------------------- 删除节点 --------------------

delete_node() {

    show_nodes

    echo

    local TOTAL

    TOTAL=$(grep -c . "$NODE_FILE" 2>/dev/null || true)

    if [ "$TOTAL" -le 1 ]; then

        warn "至少需要保留一个节点。"
        return

    fi

    read -r -p "请输入要删除的节点编号: " SELECT

    if ! [[ "$SELECT" =~ ^[0-9]+$ ]] ||
       [ "$SELECT" -lt 1 ] ||
       [ "$SELECT" -gt "$TOTAL" ]; then

        err "编号不正确。"
        return

    fi

    local UUID

    UUID=$(sed -n "${SELECT}p" "$NODE_FILE" | cut -d'|' -f1)

    sed -i "${SELECT}d" "$NODE_FILE"

    if ! build_config; then

        err "配置生成失败。"
        return 1

    fi

    create_service || return 1

    msg "节点 $UUID 已删除。"

}

# -------------------- 启动服务 --------------------

start_service() {

    systemctl start vless.service

    systemctl status vless.service --no-pager

}

# -------------------- 停止服务 --------------------

stop_service() {

    systemctl stop vless.service

    msg "VLESS 服务已停止。"

}

# -------------------- 重启服务 --------------------

restart_service() {

    systemctl restart vless.service

    systemctl status vless.service --no-pager

}

# -------------------- 服务状态 --------------------

service_status() {

    systemctl status vless.service --no-pager

}

# -------------------- 查看日志 --------------------

show_logs() {

    journalctl -u vless.service -n 50 --no-pager

}

# -------------------- 更新 sing-box --------------------

update_singbox() {

    warn "即将更新 sing-box 核心。"

    read -r -p "是否继续？[y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return

    # 先备份旧核心。

    cp "$BIN_DIR/sing-box" \
       "$BIN_DIR/sing-box.backup"

    if ! install_singbox; then

        err "更新失败，恢复旧核心。"

        mv "$BIN_DIR/sing-box.backup" \
           "$BIN_DIR/sing-box"

        return 1

    fi

    if ! "$BIN_DIR/sing-box" check -c "$CONFIG_FILE"; then

        err "新核心不兼容当前配置，恢复旧核心。"

        mv "$BIN_DIR/sing-box.backup" \
           "$BIN_DIR/sing-box"

        return 1

    fi

    rm -f "$BIN_DIR/sing-box.backup"

    systemctl restart vless.service

    msg "sing-box 更新完成。"

}

# -------------------- 更新管理脚本 --------------------

update_script() {

    if [ -z "$SCRIPT_URL" ]; then

        warn "尚未配置 SCRIPT_URL。"
        warn "请先填写自己的 GitHub Raw 脚本地址。"

        return

    fi

    local TMP_FILE="/tmp/vl-update.sh"

    msg "正在下载最新脚本..."

    curl -fL --retry 3 "$SCRIPT_URL" \
        -o "$TMP_FILE" || {

        err "下载失败。"
        return 1

    }

    bash -n "$TMP_FILE" || {

        err "新脚本语法检查失败。"
        rm -f "$TMP_FILE"

        return 1

    }

    chmod +x "$TMP_FILE"

    install -m 755 "$TMP_FILE" "$SCRIPT_FILE"

    rm -f "$TMP_FILE"

    msg "脚本更新成功。"

    exec bash "$SCRIPT_FILE"

}

# -------------------- 卸载 --------------------

uninstall_all() {

    echo
    warn "此操作将删除整个 VLESS 项目。"
    warn "包括节点、证书、核心及配置。"
    echo

    read -r -p "输入 DELETE 确认卸载: " CONFIRM

    if [ "$CONFIRM" != "DELETE" ]; then

        warn "已取消卸载。"
        return

    fi

    systemctl stop vless.service 2>/dev/null || true

    systemctl disable vless.service 2>/dev/null || true

    # 删除 acme.sh 自动续期任务。
    # 仅处理本项目专属的 acme.sh。

    if [ -x "$ACME" ]; then

        "$ACME" --uninstall >/dev/null 2>&1 || true

    fi

    rm -f "$SERVICE_FILE"

    rm -f "$SHORTCUT"

    systemctl daemon-reload

    rm -rf "$BASE_DIR"

    msg "VLESS 项目卸载完成。"

    warn "未删除系统已有的其他服务及其配置。"

    exit 0

}

# -------------------- 初始化安装 --------------------

install_all() {

    check_root

    init_dirs

    install_dependencies || return 1

    detect_arch || return 1

    echo

    input_domain || return 1

    generate_path

    echo

    msg "即将初始化 VLESS 服务。"

    echo
    warn "请确认："
    echo "1. 域名已经接入 Cloudflare。"
    echo "2. DNS 记录已经开启橙色云代理。"
    echo "3. TCP 80 和 TCP 443 可以正常访问。"
    echo "4. VPS 的 TCP 80 和 443 没有被其他程序占用。"
    echo

    read -r -p "确认开始安装？[y/N]: " CONFIRM

    [[ "$CONFIRM" =~ ^[Yy]$ ]] || return

    check_port 443 || return 1

    configure_firewall

    install_singbox || return 1

    install_acme || return 1

    issue_certificate || return 1

    create_default_node

    build_config || return 1

    create_service || return 1

    install_shortcut

    echo

    msg "VLESS 安装完成！"

    show_nodes

}

# -------------------- 主菜单 --------------------

show_menu() {

    clear

    echo -e "${CYAN}"
    echo "================================================"
    echo "        VLESS + Cloudflare CDN 管理脚本"
    echo "================================================"
    echo -e "${RESET}"

    echo "  1. 安装 / 初始化服务"
    echo "  2. 创建 VLESS 节点"
    echo "  3. 查看节点及分享链接"
    echo "  4. 删除节点"
    echo "  5. 启动服务"
    echo "  6. 停止服务"
    echo "  7. 重启服务"
    echo "  8. 查看服务状态"
    echo "  9. 查看运行日志"
    echo " 10. 更新 sing-box 核心"
    echo " 11. 更新管理脚本"
    echo " 12. 卸载脚本及全部配置"
    echo
    echo "  0. 退出"
    echo
    echo "================================================"

}

# -------------------- 主程序 --------------------

main() {

    check_root

    while true; do

        show_menu

        read -r -p "请输入选项 [0-12]: " CHOICE

        case "$CHOICE" in

            1)
                install_all
                pause
                ;;

            2)
                add_node
                pause
                ;;

            3)
                show_nodes
                pause
                ;;

            4)
                delete_node
                pause
                ;;

            5)
                start_service
                pause
                ;;

            6)
                stop_service
                pause
                ;;

            7)
                restart_service
                pause
                ;;

            8)
                service_status
                pause
                ;;

            9)
                show_logs
                pause
                ;;

            10)
                update_singbox
                pause
                ;;

            11)
                update_script
                pause
                ;;

            12)
                uninstall_all
                ;;

            0)
                exit 0
                ;;

            *)
                err "无效选项。"
                sleep 1
                ;;

        esac

    done

}

main "$@"