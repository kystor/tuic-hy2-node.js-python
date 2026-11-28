#!/usr/bin/env bash
# ============================================================
# VLESS + WebSocket + TLS + Cloudflare CDN 管理脚本
#
# 协议：VLESS
# 传输：WebSocket
# TLS：Let's Encrypt
# CDN：Cloudflare 免费 CDN
# 核心：sing-box
#
# 支持系统：Debian / Ubuntu
# 支持架构：AMD64 / ARM64
#
# 项目目录：/opt/vless
# 快捷命令：vl
#
# 不依赖 jq
# ============================================================


# ============================================================
# 一、顶部统一配置区
# ============================================================

VERSION="1.0.2"

# GitHub Raw 脚本更新地址
SCRIPT_URL="https://raw.githubusercontent.com/kystor/tuic-hy2-node.js-python/refs/heads/main/vl.sh"

# 项目目录
BASE_DIR="/opt/vless"

# 快捷命令
SHORTCUT="/usr/local/bin/vl"

# sing-box 核心
SINGBOX_BIN="${BASE_DIR}/sing-box"

# 配置文件
CONFIG_FILE="${BASE_DIR}/config/config.json"

# 节点数据库
NODE_FILE="${BASE_DIR}/data/nodes.db"

# 持久化设置
SETTINGS_FILE="${BASE_DIR}/data/settings.conf"

# 证书目录
CERT_DIR="${BASE_DIR}/cert"

# 证书文件
CERT_FILE="${CERT_DIR}/cert.pem"
KEY_FILE="${CERT_DIR}/key.pem"

# 临时目录
TEMP_DIR="${BASE_DIR}/temp"

# systemd 服务名称
SERVICE_NAME="vless"

# systemd 服务文件
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# 监听端口
LISTEN_PORT="443"

# sing-box 官方 GitHub API
GITHUB_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

# root 用户专用的 acme.sh 安装位置，避免 HOME 环境变量变化导致找不到证书账户。
ACME_HOME="/root/.acme.sh"
ACME_BIN="${ACME_HOME}/acme.sh"


# ============================================================
# 二、颜色和基础函数
# ============================================================

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
RESET='\033[0m'

info() {
    echo -e "${BLUE}[信息]${RESET} $1"
}

success() {
    echo -e "${GREEN}[成功]${RESET} $1"
}

warn() {
    echo -e "${YELLOW}[警告]${RESET} $1"
}

err() {
    echo -e "${RED}[错误]${RESET} $1"
}

pause() {
    echo
    read -rp "按回车键继续..." _
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        err "请使用 root 用户运行。"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "无法识别当前系统。"
        exit 1
    fi

    source /etc/os-release

    case "$ID" in
        debian|ubuntu)
            ;;
        *)
            err "当前仅支持 Debian 和 Ubuntu。"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            err "不支持的 CPU 架构：$(uname -m)"
            exit 1
            ;;
    esac
}

create_directories() {
    mkdir -p \
        "${BASE_DIR}/config" \
        "${BASE_DIR}/data" \
        "${CERT_DIR}" \
        "${TEMP_DIR}"
}

install_dependencies() {
    info "正在安装基础依赖..."

    apt-get update || return 1

    apt-get install -y \
        curl \
        wget \
        tar \
        gzip \
        openssl \
        ca-certificates \
        python3 \
        socat \
        cron \
        iproute2

    if [[ $? -ne 0 ]]; then
        err "依赖安装失败。"
        return 1
    fi

    success "基础依赖安装完成。"
}


# ============================================================
# 三、端口检查
# ============================================================

# 检查指定 TCP 端口是否已经被占用。
#
# 返回值：
# 0 = 端口空闲
# 1 = 端口被占用

check_port() {
    local port="$1"

    if ss -H -lnt "sport = :${port}" 2>/dev/null | grep -q .; then
        return 1
    fi

    return 0
}

show_port_process() {
    local port="$1"

    echo
    info "TCP ${port} 端口占用情况："

    ss -lntp "sport = :${port}" 2>/dev/null || true
}


# ============================================================
# 四、域名与设置持久化
# ============================================================

DOMAIN=""
WS_PATH=""

# 读取设置文件。
#
# 不使用 source，避免把设置文件当成 Shell 脚本执行。

load_settings() {
    DOMAIN=""
    WS_PATH=""

    if [[ ! -f "$SETTINGS_FILE" ]]; then
        return
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            DOMAIN)
                DOMAIN="$value"
                ;;
            WS_PATH)
                WS_PATH="$value"
                ;;
        esac
    done < "$SETTINGS_FILE"
}

# 保存域名和 WebSocket 路径。

save_settings() {
    local temp_file="${SETTINGS_FILE}.tmp"

    {
        echo "DOMAIN=${DOMAIN}"
        echo "WS_PATH=${WS_PATH}"
    } > "$temp_file"

    chmod 600 "$temp_file"
    mv -f "$temp_file" "$SETTINGS_FILE"
}

# 验证完整域名。
#
# 不限制 cdn、abc、aaa 等前缀。
# 支持：
# example.com
# cdn.example.com
# abc.example.com
# aaa.example.com
# a.b.example.com
#
# 国际化域名需要先转换为 Punycode。

validate_domain() {
    local domain="$1"
    local label
    local labels=()

    [[ -z "$domain" ]] && return 1
    [[ ${#domain} -gt 253 ]] && return 1

    # 必须全部为 ASCII 字符。
    [[ "$domain" =~ [^a-zA-Z0-9.-] ]] && return 1

    # 不允许首尾为点。
    [[ "$domain" == .* || "$domain" == *. ]] && return 1

    IFS='.' read -r -a labels <<< "$domain"

    # 至少需要两个域名标签。
    [[ ${#labels[@]} -lt 2 ]] && return 1

    for label in "${labels[@]}"; do

        # 每个标签长度不能超过 63。
        [[ ${#label} -lt 1 || ${#label} -gt 63 ]] && return 1

        # 标签不能以 - 开头或结尾。
        [[ "$label" == -* || "$label" == *- ]] && return 1

        # 标签只能由字母、数字和连字符组成。
        if [[ ! "$label" =~ ^[a-zA-Z0-9-]+$ ]]; then
            return 1
        fi
    done

    return 0
}

input_domain() {
    echo
    echo "请输入用于 Cloudflare CDN 的完整域名。"
    echo
    echo "例如："
    echo "  cdn.example.com"
    echo "  abc.example.com"
    echo "  aaa.example.com"
    echo "  example.com"
    echo

    while true; do
        read -rp "请输入域名：" DOMAIN

        DOMAIN="${DOMAIN,,}"

        if validate_domain "$DOMAIN"; then
            success "域名格式正确：${DOMAIN}"
            break
        fi

        err "域名格式不正确，请重新输入。"
    done
}

generate_ws_path() {
    # 随机生成 WebSocket 路径。
    # 例如：/a8f12c9e7b32d410

    WS_PATH="/$(openssl rand -hex 8)"
}

validate_ws_path() {
    [[ "$WS_PATH" =~ ^/[a-fA-F0-9]{16}$ ]]
}


# ============================================================
# 五、节点数据库
# ============================================================

init_node_database() {
    touch "$NODE_FILE"
    chmod 600 "$NODE_FILE"
}

generate_uuid() {
    cat /proc/sys/kernel/random/uuid
}

# 创建节点。

add_node() {
    echo

    read -rp "请输入节点名称：" node_name

    if [[ -z "$node_name" ]]; then
        err "节点名称不能为空。"
        return 1
    fi

    # 避免特殊字符破坏数据库格式。

    node_name="${node_name//|/_}"
    node_name="${node_name//$'\n'/}"
    node_name="${node_name//$'\r'/}"

    local uuid
    uuid=$(generate_uuid)

    echo "${uuid}|${node_name}" >> "$NODE_FILE"

    chmod 600 "$NODE_FILE"

    if ! generate_config; then
        err "配置生成失败，正在撤销本次节点添加。"

        sed -i "\|^${uuid}|d" "$NODE_FILE"

        return 1
    fi

    if ! restart_service; then
        warn "新节点导致服务启动失败，正在回滚节点数据库和配置。"
        local rollback_file="${TEMP_DIR}/nodes.rollback"
        grep -Fvx "${uuid}|${node_name}" "$NODE_FILE" > "$rollback_file" || true
        mv -f "$rollback_file" "$NODE_FILE"
        chmod 600 "$NODE_FILE"
        generate_config >/dev/null 2>&1 || true
        return 1
    fi

    success "节点创建成功。"

    echo "名称：${node_name}"
    echo "UUID：${uuid}"

    show_node_link "$uuid" "$node_name"
}

# 查看节点。

list_nodes() {
    echo
    echo "==================== VLESS 节点列表 ===================="

    if [[ ! -s "$NODE_FILE" ]]; then
        warn "当前没有节点。"
        return 1
    fi

    local index=0

    while IFS='|' read -r uuid name; do
        [[ -z "$uuid" ]] && continue

        index=$((index + 1))

        echo
        echo "编号：${index}"
        echo "名称：${name}"
        echo "UUID：${uuid}"

    done < "$NODE_FILE"

    echo
    echo "========================================================="

    return 0
}

# 删除节点。

delete_node() {
    list_nodes || return 1

    echo

    read -rp "请输入要删除的节点编号：" number

    if ! [[ "$number" =~ ^[0-9]+$ ]] || [[ "$number" -lt 1 ]]; then
        err "编号无效。"
        return 1
    fi

    local temp_file="${TEMP_DIR}/nodes.tmp"
    local index=0
    local found=0

    : > "$temp_file"

    while IFS='|' read -r uuid name; do
        [[ -z "$uuid" ]] && continue

        index=$((index + 1))

        if [[ "$index" -eq "$number" ]]; then
            found=1
            continue
        fi

        echo "${uuid}|${name}" >> "$temp_file"

    done < "$NODE_FILE"

    if [[ "$found" -ne 1 ]]; then
        rm -f "$temp_file"
        err "没有找到对应节点。"
        return 1
    fi

    local backup_file="${TEMP_DIR}/nodes.before-delete"
    cp -f "$NODE_FILE" "$backup_file"
    mv -f "$temp_file" "$NODE_FILE"
    chmod 600 "$NODE_FILE"

    if [[ -s "$NODE_FILE" ]]; then
        if ! generate_config || ! restart_service; then
            warn "删除后配置或服务检查失败，正在恢复原节点数据库。"
            cp -f "$backup_file" "$NODE_FILE"
            chmod 600 "$NODE_FILE"
            generate_config >/dev/null 2>&1 || true
            restart_service >/dev/null 2>&1 || true
            rm -f "$backup_file"
            return 1
        fi
    else
        # 不允许生成空用户配置。
        # 删除最后一个节点时，停止服务并保留空数据库。

        stop_service
        warn "所有节点已删除，服务已停止。"
    fi

    rm -f "${TEMP_DIR}/nodes.before-delete"
    success "节点删除完成。"
}


# ============================================================
# 六、sing-box 核心安装与更新
# ============================================================

install_singbox() {
    info "正在获取 sing-box 最新版本..."

    local api_file="${TEMP_DIR}/release.json"

    if ! curl -fsSL "$GITHUB_API" -o "$api_file"; then
        err "无法获取 sing-box 版本信息。"
        return 1
    fi

    # 使用 Python 从 GitHub API 中查找对应架构的安装包。

    local download_url

    download_url=$(python3 - "$api_file" "$ARCH" <<'PY'
import json
import sys

file_path = sys.argv[1]
arch = sys.argv[2]

with open(file_path, "r", encoding="utf-8") as f:
    data = json.load(f)

for asset in data.get("assets", []):
    name = asset.get("name", "")

    expected = f"linux-{arch}.tar.gz"

    if name.endswith(expected) and "sing-box-" in name:
        print(asset.get("browser_download_url", ""))
        break
PY
)

    if [[ -z "$download_url" ]]; then
        err "没有找到适合当前架构的 sing-box 安装包。"
        return 1
    fi

    local archive="${TEMP_DIR}/sing-box.tar.gz"
    local extract_dir="${TEMP_DIR}/sing-box-extract"

    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    info "正在下载 sing-box..."

    if ! curl -fL "$download_url" -o "$archive"; then
        err "sing-box 下载失败。"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$extract_dir"; then
        err "sing-box 压缩包解压失败。"
        return 1
    fi

    local new_bin

    new_bin=$(find "$extract_dir" -type f -name sing-box | head -n 1)

    if [[ -z "$new_bin" ]]; then
        err "压缩包中没有找到 sing-box 程序。"
        return 1
    fi

    chmod 755 "$new_bin"

    if ! "$new_bin" version >/dev/null 2>&1; then
        err "下载的 sing-box 无法正常运行。"
        return 1
    fi

    # 备份旧核心。

    if [[ -f "$SINGBOX_BIN" ]]; then
        cp -f "$SINGBOX_BIN" "${SINGBOX_BIN}.bak"
    fi

    install -m 755 "$new_bin" "${SINGBOX_BIN}.new"

    if ! "${SINGBOX_BIN}.new" version >/dev/null 2>&1; then
        err "新核心检查失败。"
        rm -f "${SINGBOX_BIN}.new"
        return 1
    fi

    # 已安装环境更新核心时，先用新核心检查当前配置。
    # 检查不通过就保留旧核心，避免更新后服务无法启动。
    if [[ -s "$CONFIG_FILE" ]]; then
        if ! "${SINGBOX_BIN}.new" check -c "$CONFIG_FILE"; then
            err "新版本 sing-box 与当前配置不兼容，取消核心更新。"
            rm -f "${SINGBOX_BIN}.new"
            return 1
        fi
    fi

    mv -f "${SINGBOX_BIN}.new" "$SINGBOX_BIN"

    rm -rf "$extract_dir"
    rm -f "$archive"

    success "sing-box 安装或更新完成。"

    "$SINGBOX_BIN" version | head -n 1
}


# ============================================================
# 七、Let's Encrypt 证书管理
# ============================================================

install_acme() {
    # 本脚本要求以 root 运行，因此统一使用 /root/.acme.sh。
    if [[ -x "$ACME_BIN" ]]; then
        "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null 2>&1 || {
            err "设置 Let's Encrypt 默认 CA 失败。"
            return 1
        }
        return 0
    fi

    info "正在安装 acme.sh..."

    # 明确将安装脚本交给 bash 执行，避免依赖当前用户的交互式 Shell。
    if ! curl -fsSL https://get.acme.sh | sh; then
        err "acme.sh 安装失败。"
        return 1
    fi

    if [[ ! -x "$ACME_BIN" ]]; then
        err "没有找到 acme.sh 程序：${ACME_BIN}"
        return 1
    fi

    if ! "$ACME_BIN" --set-default-ca --server letsencrypt >/dev/null; then
        err "设置 Let's Encrypt 为默认 CA 失败。"
        return 1
    fi

    success "acme.sh 安装完成。"
}

# 验证本地证书是否属于当前域名，并且至少还有指定秒数的有效期。
certificate_is_valid() {
    local min_seconds="${1:-86400}"

    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || return 1

    openssl x509 -in "$CERT_FILE" -noout -checkend "$min_seconds" >/dev/null 2>&1 || return 1

    # 用 SAN 验证域名；不能只依赖 CN，因为现代证书主要使用 subjectAltName。
    openssl x509 -in "$CERT_FILE" -noout -ext subjectAltName 2>/dev/null |
        tr ',' '\n' |
        sed -E 's/^[[:space:]]*DNS://; s/^[[:space:]]+//; s/[[:space:]]+$//' |
        grep -Fxq "$DOMAIN" || return 1

    # 检查证书和私钥是否匹配（兼容 ECC/RSA）。
    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$CERT_FILE" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')

    [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

install_issued_certificate() {
    # reloadcmd 在服务尚未创建或服务停止时必须正常返回 0。
    # 这样首次签发不会因为 vless.service 尚不存在而被误判为安装失败。
    "$ACME_BIN" --install-cert \
        -d "$DOMAIN" \
        --ecc \
        --key-file "$KEY_FILE" \
        --fullchain-file "$CERT_FILE" \
        --reloadcmd "if systemctl is-active --quiet ${SERVICE_NAME}.service; then systemctl restart ${SERVICE_NAME}.service; fi" || {
            err "acme.sh 安装证书文件失败。"
            return 1
        }

    [[ -s "$CERT_FILE" && -s "$KEY_FILE" ]] || {
        err "证书安装后文件不存在或为空。"
        return 1
    }

    chmod 600 "$KEY_FILE"
    chmod 644 "$CERT_FILE"

    if ! certificate_is_valid 3600; then
        err "安装后的证书域名、有效期或私钥匹配检查失败。"
        return 1
    fi

    return 0
}

issue_certificate() {
    info "准备检查 Let's Encrypt 证书..."

    install_acme || return 1
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"

    # 本地证书有效期超过 30 天：只重新部署到项目目录，不重新签发。
    if certificate_is_valid 2592000; then
        success "检测到当前域名已有有效证书（剩余有效期超过 30 天），跳过重复申请。"
        install_issued_certificate || return 1
        success "现有证书已安装到项目目录。"
        return 0
    fi

    # 证书可能已经由 acme.sh 成功签发，但上次复制到 /opt/vless 时中断。
    # 先检查 acme.sh 自己保存的证书；有效则直接重新安装，不再次申请。
    local acme_cert="${ACME_HOME}/${DOMAIN}_ecc/${DOMAIN}.cer"
    if [[ -s "$acme_cert" ]] &&
       openssl x509 -in "$acme_cert" -noout -checkend 3600 >/dev/null 2>&1; then
        info "发现 acme.sh 已签发的证书，尝试重新安装，避免重复签发。"
        if install_issued_certificate && certificate_is_valid 3600; then
            success "已复用 acme.sh 中现有证书。"
            return 0
        fi
        warn "现有 ACME 证书无法正常部署，将尝试续期。"
    fi

    # 已有 ACME 证书但即将过期时，走 renew；没有证书时才走 issue。
    if [[ -s "$acme_cert" ]]; then
        info "现有证书即将过期，正在尝试续期..."
        if ! "$ACME_BIN" --renew -d "$DOMAIN" --ecc --server letsencrypt; then
            err "现有证书续期失败。"
            return 1
        fi
        install_issued_certificate || return 1
        success "Let's Encrypt 证书续期及安装完成。"
        return 0
    fi

    # HTTP-01 standalone 模式需要 TCP 80 空闲。
    if ! check_port 80; then
        err "TCP 80 端口已经被占用，无法使用 standalone 模式申请证书。"
        show_port_process 80
        return 1
    fi

    echo
    echo "申请证书前请确认："
    echo
    echo "1. 域名已经添加到 Cloudflare。"
    echo "2. DNS 记录指向当前 VPS 公网 IP。"
    echo "3. Cloudflare DNS 记录状态符合 HTTP-01 验证要求。"
    echo "4. VPS 防火墙允许 TCP 80 入站。"
    echo "5. 云服务商安全组允许 TCP 80 入站。"
    echo

    read -rp "确认以上条件已经完成？(y/n)：" answer

    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        warn "已取消证书申请。"
        return 1
    fi

    info "正在申请 ${DOMAIN} 的 Let's Encrypt 证书..."

    if ! "$ACME_BIN" \
        --issue \
        --server letsencrypt \
        --standalone \
        -d "$DOMAIN" \
        --keylength ec-256; then
        err "证书申请失败。请检查 DNS、TCP 80、防火墙和 Cloudflare 代理状态。"
        return 1
    fi

    install_issued_certificate || return 1
    success "Let's Encrypt 证书申请及安装完成。"
}

check_certificate() {
    if [[ ! -s "$CERT_FILE" || ! -s "$KEY_FILE" ]]; then
        err "证书文件不存在，请先申请证书。"
        return 1
    fi

    return 0
}


# ============================================================
# 八、生成 sing-box 配置
# ============================================================

generate_config() {
    check_certificate || return 1

    if [[ ! -s "$NODE_FILE" ]]; then
        err "节点数据库为空。"
        return 1
    fi

    if ! validate_domain "$DOMAIN"; then
        err "当前域名设置不正确。"
        return 1
    fi

    if ! validate_ws_path; then
        err "WebSocket 路径不正确。"
        return 1
    fi

    if [[ ! -x "$SINGBOX_BIN" ]]; then
        err "没有找到 sing-box 核心，请先安装或更新核心。"
        return 1
    fi

    info "正在生成 sing-box 配置..."

    # 先生成到临时文件；只有通过 sing-box check 后才替换正式配置。
    local temp_config="${CONFIG_FILE}.tmp"
    rm -f "$temp_config"

    if ! python3 - \
        "$NODE_FILE" \
        "$temp_config" \
        "$CERT_FILE" \
        "$KEY_FILE" \
        "$WS_PATH" \
        <<'PY'
import json
import os
import sys
import uuid

node_file, config_file, cert_file, key_file, ws_path = sys.argv[1:6]
users = []
seen = set()

with open(node_file, "r", encoding="utf-8") as f:
    for line_no, line in enumerate(f, 1):
        line = line.rstrip("\r\n")
        if not line or "|" not in line:
            continue

        user_uuid, name = line.split("|", 1)
        try:
            parsed = str(uuid.UUID(user_uuid))
        except ValueError:
            print("节点数据库第 {} 行 UUID 无效：{}".format(line_no, user_uuid))
            sys.exit(1)

        if parsed in seen:
            print("节点数据库存在重复 UUID：{}".format(parsed))
            sys.exit(1)
        seen.add(parsed)

        users.append({"name": name, "uuid": parsed})

if not users:
    print("节点数据库中没有有效节点。")
    sys.exit(1)

config = {
    "log": {"level": "info", "timestamp": True},
    "inbounds": [{
        "type": "vless",
        "tag": "vless-in",
        "listen": "::",
        "listen_port": 443,
        "users": users,
        "tls": {
            "enabled": True,
            "certificate_path": cert_file,
            "key_path": key_file
        },
        "transport": {
            "type": "ws",
            "path": ws_path
        }
    }],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
    ]
}

with open(config_file, "w", encoding="utf-8") as f:
    json.dump(config, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    then
        rm -f "$temp_config"
        err "配置文件生成失败。"
        return 1
    fi

    chmod 600 "$temp_config"

    if ! "$SINGBOX_BIN" check -c "$temp_config"; then
        rm -f "$temp_config"
        err "sing-box 配置检查失败，保留原有配置不变。"
        return 1
    fi

    mv -f "$temp_config" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    success "配置生成并检查通过。"
}



# ============================================================
# 九、systemd 服务
# ============================================================

create_service() {
    info "正在创建 systemd 服务..."

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=VLESS WebSocket TLS Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"

    success "systemd 服务创建完成。"
}

restart_service() {
    if [[ ! -f "$SERVICE_FILE" ]]; then
        err "systemd 服务尚未创建。"
        return 1
    fi

    if ! "$SINGBOX_BIN" check -c "$CONFIG_FILE"; then
        err "配置检查失败，取消重启。"
        return 1
    fi

    systemctl restart "$SERVICE_NAME" || {
        err "systemd 重启命令执行失败。"
        return 1
    }

    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "VLESS 服务运行正常。"
        return 0
    fi

    err "VLESS 服务启动失败。"

    echo
    systemctl status "$SERVICE_NAME" --no-pager -l

    return 1
}

start_service() {
    systemctl start "$SERVICE_NAME"

    sleep 1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        success "服务已启动。"
    else
        err "服务启动失败。"
        systemctl status "$SERVICE_NAME" --no-pager -l
    fi
}

stop_service() {
    systemctl stop "$SERVICE_NAME"
    success "VLESS 服务已停止。"
}

service_status() {
    systemctl status "$SERVICE_NAME" --no-pager -l
}


# ============================================================
# 十、生成 VLESS 分享链接
# ============================================================

show_node_link() {
    local uuid="$1"
    local name="$2"

    local link

    # 使用 Python 对节点名称进行 URL 编码。
    # 避免中文、空格或特殊符号导致分享链接异常。

    local encoded_name

    encoded_name=$(python3 - "$name" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
)

    local encoded_path

    encoded_path=$(python3 - "$WS_PATH" <<'PY'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=""))
PY
)

    link="vless://${uuid}@${DOMAIN}:${LISTEN_PORT}?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${encoded_path}#${encoded_name}"

    echo
    echo "==================== VLESS 节点链接 ===================="
    echo
    echo "$link"
    echo
    echo "========================================================="
}

show_all_links() {
    if [[ ! -s "$NODE_FILE" ]]; then
        warn "当前没有节点。"
        return 1
    fi

    while IFS='|' read -r uuid name; do
        [[ -z "$uuid" ]] && continue

        show_node_link "$uuid" "$name"

    done < "$NODE_FILE"
}


# ============================================================
# 十一、更新管理脚本
# ============================================================

update_script() {
    info "正在下载最新管理脚本..."

    if [[ -z "$SCRIPT_URL" ]]; then
        err "SCRIPT_URL 未配置。"
        return 1
    fi

    local new_file="${TEMP_DIR}/vl.sh.new"

    if ! curl -fL "$SCRIPT_URL" -o "$new_file"; then
        err "脚本下载失败。"
        rm -f "$new_file"
        return 1
    fi

    # 先检查 Bash 语法。
    # 检查失败不会覆盖现有脚本。

    if ! bash -n "$new_file"; then
        err "新脚本语法检查失败，取消更新。"
        rm -f "$new_file"
        return 1
    fi

    # 备份当前脚本。

    if [[ -f "${BASE_DIR}/vl.sh" ]]; then
        cp -f "${BASE_DIR}/vl.sh" "${BASE_DIR}/vl.sh.bak"
    fi

    install -m 755 "$new_file" "${BASE_DIR}/vl.sh"

    ln -sf "${BASE_DIR}/vl.sh" "$SHORTCUT"

    rm -f "$new_file"

    success "管理脚本更新完成。"

    echo
    info "正在重新启动管理菜单..."

    exec bash "${BASE_DIR}/vl.sh"
}


# ============================================================
# 十二、安装快捷命令
# ============================================================

install_shortcut() {
    local target="${BASE_DIR}/vl.sh"

    # 如果脚本已经保存在项目目录中，直接创建快捷入口。

    if [[ -f "$target" ]]; then
        chmod 755 "$target"
        ln -sf "$target" "$SHORTCUT"
        return 0
    fi

    # 首次通过 bash <(curl ...) 运行时，
    # $0 可能是 /dev/fd/xxx，不能直接复制。
    # 所以通过顶部配置的 GitHub Raw 地址重新下载。

    if ! curl -fsSL "$SCRIPT_URL" -o "$target"; then
        err "无法下载脚本文件，快捷命令创建失败。"
        return 1
    fi

    if ! bash -n "$target"; then
        err "下载的脚本语法检查失败。"
        rm -f "$target"
        return 1
    fi

    chmod 755 "$target"

    ln -sf "$target" "$SHORTCUT"

    success "快捷命令 vl 已创建。"
}


# ============================================================
# 十三、首次安装
# ============================================================

install_all() {
    echo
    echo "========================================================="
    echo "          VLESS + Cloudflare CDN 安装程序"
    echo "========================================================="
    echo

    if [[ -f "$CONFIG_FILE" ]]; then
        warn "检测到已有配置文件。"
        return 1
    fi

    install_dependencies || return 1
    create_directories
    init_node_database

    # 先检查服务端口，避免端口冲突时已经改写域名设置或申请证书。
    if ! check_port "$LISTEN_PORT"; then
        err "TCP ${LISTEN_PORT} 已经被其他程序占用。"
        show_port_process "$LISTEN_PORT"
        return 1
    fi

    # 如果上一次安装已经保存了域名和 WS 路径，则继续使用，避免重复询问。
    if [[ -n "$DOMAIN" && -n "$WS_PATH" ]] && validate_domain "$DOMAIN" && validate_ws_path; then
        info "检测到已保存的域名和 WebSocket 路径，继续使用现有设置。"
    else
        input_domain
        generate_ws_path
        save_settings
    fi

    # 核心和证书安装完成后再写入默认节点及正式配置。
    install_singbox || return 1
    issue_certificate || return 1

    local uuid
    uuid=$(generate_uuid)

    echo "${uuid}|default" >> "$NODE_FILE"
    chmod 600 "$NODE_FILE"

    if ! generate_config; then
        err "配置生成失败。"
        return 1
    fi

    create_service
    restart_service || return 1

    install_shortcut || warn "快捷命令安装失败，请检查 GitHub 下载地址。"

    echo
    success "VLESS 安装完成！"
    echo
    echo "域名：${DOMAIN}"
    echo "端口：${LISTEN_PORT}"
    echo "WebSocket 路径：${WS_PATH}"
    show_node_link "$uuid" "default"
    echo
    info "以后可以使用 vl 命令管理节点。"
    echo
}



# ============================================================
# 十四、重新申请证书
# ============================================================

renew_certificate() {
    echo
    warn "将检查并更新当前域名证书：${DOMAIN}"
    read -rp "确定继续？(y/n)：" answer

    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
        warn "已取消。"
        return 1
    fi

    install_acme || return 1

    # 证书不存在时执行首次签发；存在时交给 acme.sh 按续期策略处理。
    if [[ ! -s "$ACME_HOME/${DOMAIN}_ecc/${DOMAIN}.cer" ]]; then
        issue_certificate || return 1
    else
        "$ACME_BIN" --renew -d "$DOMAIN" --ecc --server letsencrypt || {
            err "acme.sh 续期命令失败。"
            return 1
        }
        install_issued_certificate || return 1
    fi

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        restart_service
    else
        success "证书已更新；VLESS 服务当前未运行，因此没有执行重启。"
    fi
}



# ============================================================
# 十五、卸载
# ============================================================

uninstall_all() {
    echo

    warn "即将卸载 VLESS 管理脚本。"

    echo
    echo "将删除："
    echo "1. VLESS systemd 服务。"
    echo "2. /opt/vless 目录。"
    echo "3. vl 快捷命令。"

    echo
    echo "不会删除："
    echo "1. 系统已有的 acme.sh。"
    echo "2. 其他代理服务。"
    echo "3. 其他 systemd 服务。"

    echo

    read -rp "确定卸载吗？输入 yes 确认：" answer

    if [[ "$answer" != "yes" ]]; then
        warn "已取消卸载。"
        return
    fi

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true

    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload

    rm -f "$SHORTCUT"

    rm -rf "$BASE_DIR"

    success "VLESS 已卸载。"
}


# ============================================================
# 十六、菜单
# ============================================================

show_menu() {
    clear

    echo -e "${CYAN}"
    echo "========================================================="
    echo "              VLESS + Cloudflare CDN"
    echo "========================================================="
    echo -e "${RESET}"

    echo "版本：${VERSION}"
    echo "域名：${DOMAIN}"
    echo "端口：${LISTEN_PORT}"
    echo "WebSocket：${WS_PATH}"

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        echo -e "状态：${GREEN}运行中${RESET}"
    else
        echo -e "状态：${RED}未运行${RESET}"
    fi

    echo
    echo "---------------------- 节点管理 -------------------------"
    echo " 1. 创建 VLESS 节点"
    echo " 2. 查看所有节点及链接"
    echo " 3. 删除 VLESS 节点"

    echo
    echo "---------------------- 服务管理 -------------------------"
    echo " 4. 启动服务"
    echo " 5. 停止服务"
    echo " 6. 重启服务"
    echo " 7. 查看服务状态"
    echo " 8. 查看运行日志"

    echo
    echo "---------------------- 核心管理 -------------------------"
    echo " 9. 更新 sing-box 核心"

    echo
    echo "---------------------- 脚本管理 -------------------------"
    echo "10. 更新管理脚本"
    echo "11. 重新申请证书"
    echo "12. 重新生成配置"
    echo "13. 卸载脚本"

    echo
    echo " 0. 退出"

    echo
    echo "========================================================="
}

main() {
    require_root

    check_os

    create_directories

    load_settings

    init_node_database

    while true; do

        show_menu

        read -rp "请输入选项：" choice

        case "$choice" in

            1)
                add_node
                pause
                ;;

            2)
                show_all_links
                pause
                ;;

            3)
                delete_node
                pause
                ;;

            4)
                start_service
                pause
                ;;

            5)
                stop_service
                pause
                ;;

            6)
                restart_service
                pause
                ;;

            7)
                service_status
                pause
                ;;

            8)
                journalctl -u "$SERVICE_NAME" -n 80 --no-pager
                pause
                ;;

            9)
                if install_singbox; then
                    if [[ -f "$CONFIG_FILE" ]]; then
                        restart_service
                    fi
                fi
                pause
                ;;

            10)
                update_script
                ;;

            11)
                renew_certificate
                pause
                ;;

            12)
                if generate_config; then
                    restart_service
                fi
                pause
                ;;

            13)
                uninstall_all
                exit 0
                ;;

            0)
                echo "已退出。"
                exit 0
                ;;

            *)
                err "无效选项。"
                sleep 1
                ;;

        esac
    done
}


# ============================================================
# 十七、程序入口
# ============================================================

require_root

check_os

create_directories

load_settings

init_node_database

# 如果核心配置文件不存在，则执行首次安装。

if [[ ! -f "$CONFIG_FILE" ]]; then

    install_all

    exit $?

fi

# 已安装状态下，检查持久化设置。

if [[ -z "$DOMAIN" || -z "$WS_PATH" ]]; then
    err "域名或 WebSocket 路径缺失。"
    err "请检查：${SETTINGS_FILE}"
    exit 1
fi

# 检查 WebSocket 路径格式。

if ! validate_ws_path; then
    err "WebSocket 路径格式异常。"
    exit 1
fi

# 检查域名格式。

if ! validate_domain "$DOMAIN"; then
    err "保存的域名格式异常。"
    exit 1
fi

# 启动管理菜单。

main