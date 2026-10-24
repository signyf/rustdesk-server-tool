#!/bin/bash
# =============================================================================
# RustDesk Server (OSS) 一键安装 / 管理脚本
# 仓库: https://github.com/signyf/rustdesk-server-tool
# 说明: 部署官方 rustdesk-server 的 hbbs(ID/信令) 与 hbbr(中继) 两个服务,
#       以 systemd 方式运行。参数与端口依据 RustDesk 官方文档:
#       https://rustdesk.com/docs/en/self-host/rustdesk-server-oss/
# 用法: 以 root 运行,无参数进入菜单;也可直接传子命令:
#       install | uninstall | status | key | start | stop | restart |
#       upgrade | update-self
# =============================================================================

export LANG=en_US.UTF-8
set -o pipefail

# ----------------------------- 基础配置 --------------------------------------
INSTALL_DIR="/usr/local/rustdesk-server"      # 二进制与数据(密钥/数据库)目录
UNIT_DIR="/etc/systemd/system"
HBBS_SERVICE="rustdesk-hbbs"
HBBR_SERVICE="rustdesk-hbbr"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/signyf/rustdesk-server-tool/main/rustdesk-server-tool.sh"
FALLBACK_VERSION="1.1.16"                       # 取不到最新版时的兜底版本
# GitHub 下载加速镜像(仅在直连失败时依次兜底)
MIRRORS=(
    "https://gh-proxy.com"
    "https://gh.ddlc.top"
    "https://edgeone.gh-proxy.com"
    "https://cdn.gh-proxy.com"
    "https://hk.gh-proxy.com"
)
DL_TIMEOUT=20

# ----------------------------- 输出小工具 ------------------------------------
c_red()    { printf '\033[0;31;31m%b\033[0m\n' "$1"; }
c_green()  { printf '\033[0;31;32m%b\033[0m\n' "$1"; }
c_yellow() { printf '\033[0;31;33m%b\033[0m\n' "$1"; }
c_blue()   { printf '\033[0;31;36m%b\033[0m\n' "$1"; }
info()     { c_blue "[*] $1"; }
ok()       { c_green "[+] $1"; }
warn()     { c_yellow "[!] $1"; }
err()      { c_red "[x] $1"; }

pause_back() {
    echo
    read -n1 -r -s -p "按任意键返回菜单...(Ctrl+C 退出)" _ || true
    echo
}

# ----------------------------- 环境检查 --------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "请使用 root 用户运行此脚本"
        exit 1
    fi
}

require_systemd() {
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
        err "未检测到 systemd,本脚本仅支持使用 systemd 的发行版"
        exit 1
    fi
}

# 包管理器:仅用于补装 wget/curl/unzip 之类的小依赖
pkg_install() {
    local pkgs=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "${pkgs[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${pkgs[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${pkgs[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${pkgs[@]}"
    else
        return 1
    fi
}

ensure_tools() {
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        warn "未检测到 wget/curl,尝试安装 wget"
        pkg_install wget || { err "wget 安装失败,请手动安装后重试"; exit 1; }
    fi
    if ! command -v unzip >/dev/null 2>&1; then
        warn "未检测到 unzip,尝试安装"
        pkg_install unzip || { err "unzip 安装失败,请手动安装后重试"; exit 1; }
    fi
}

# 原始下载(不经镜像):成功返回 0
fetch_direct() {
    local url="$1" dest="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$DL_TIMEOUT" -O "$dest" "$url"
    else
        curl -fsSL --connect-timeout "$DL_TIMEOUT" -o "$dest" "$url"
    fi
}

# 下载:先直连 GitHub,失败再依次尝试镜像;成功且文件非空返回 0
download() {
    local url="$1" dest="$2" base
    if fetch_direct "$url" "$dest" && [[ -s "$dest" ]]; then
        return 0
    fi
    warn "直连下载失败,尝试加速镜像..."
    for base in "${MIRRORS[@]}"; do
        if fetch_direct "${base}/${url}" "$dest" && [[ -s "$dest" ]]; then
            info "已通过镜像下载: ${base}"
            return 0
        fi
    done
    rm -f "$dest"
    return 1
}

# ----------------------------- 版本与架构 ------------------------------------
# 从 GitHub API 取 rustdesk-server 最新版本号(形如 1.1.16),失败用兜底版本
latest_version() {
    local v=""
    if command -v wget >/dev/null 2>&1; then
        v=$(wget -qO- --timeout=10 "https://api.github.com/repos/rustdesk/rustdesk-server/releases/latest" 2>/dev/null \
            | grep -m1 '"tag_name"' | sed -E 's/.*"v?([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
    fi
    if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$v"
    else
        echo "$FALLBACK_VERSION"
    fi
}

# 已安装版本(安装时写入 $INSTALL_DIR/version.txt)
installed_version() {
    if [[ -f "$INSTALL_DIR/version.txt" ]]; then
        cat "$INSTALL_DIR/version.txt"
    else
        echo ""
    fi
}

# 机器架构 -> 官方发布包命名
detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64)   echo "amd64" ;;
        aarch64 | arm64)  echo "arm64" ;;
        armv7l | armv7)   echo "armv7" ;;
        i386 | i686)      echo "i386" ;;
        *)
            err "暂不支持的架构: $(uname -m)"
            exit 1
            ;;
    esac
}

# 服务是否已安装(以 systemd 单元文件为准)
is_installed() {
    [[ -f "$UNIT_DIR/${HBBS_SERVICE}.service" && -f "$UNIT_DIR/${HBBR_SERVICE}.service" ]]
}

status_text() {
    if ! is_installed; then
        echo "未安装"
    elif systemctl is-active --quiet "$HBBS_SERVICE" && systemctl is-active --quiet "$HBBR_SERVICE"; then
        echo "运行中"
    else
        echo "已停止"
    fi
}

# ----------------------------- systemd 单元 ----------------------------------
write_units() {
    cat >"$UNIT_DIR/${HBBS_SERVICE}.service" <<EOF
[Unit]
Description=RustDesk hbbs (ID/Rendezvous server)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/hbbs
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    cat >"$UNIT_DIR/${HBBR_SERVICE}.service" <<EOF
[Unit]
Description=RustDesk hbbr (Relay server)
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/hbbr
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

start_services() {
    systemctl start "$HBBS_SERVICE" "$HBBR_SERVICE"
}

stop_services() {
    systemctl stop "$HBBS_SERVICE" "$HBBR_SERVICE" 2>/dev/null || true
}

# ----------------------------- 安装 / 升级 -----------------------------------
# 下载并解压指定版本发布包,只替换二进制(密钥与数据库保留在 $INSTALL_DIR)
deploy_binaries() {
    local version="$1" arch tmpdir zipname
    arch=$(detect_arch)
    zipname="rustdesk-server-linux-${arch}.zip"
    tmpdir=$(mktemp -d)

    info "下载 rustdesk-server ${version} (${arch}) ..."
    if ! download "https://github.com/rustdesk/rustdesk-server/releases/download/${version}/${zipname}" "$tmpdir/$zipname"; then
        err "下载失败,请检查网络后重试"
        rm -rf "$tmpdir"
        return 1
    fi
    if ! unzip -t "$tmpdir/$zipname" >/dev/null 2>&1; then
        err "压缩包校验失败,文件可能不完整"
        rm -rf "$tmpdir"
        return 1
    fi
    unzip -qo "$tmpdir/$zipname" -d "$tmpdir"
    mkdir -p "$INSTALL_DIR"
    install -m 0755 "$tmpdir/$arch/hbbs" "$INSTALL_DIR/hbbs"
    install -m 0755 "$tmpdir/$arch/hbbr" "$INSTALL_DIR/hbbr"
    if [[ -f "$tmpdir/$arch/rustdesk-utils" ]]; then
        install -m 0755 "$tmpdir/$arch/rustdesk-utils" "$INSTALL_DIR/rustdesk-utils"
    fi
    echo "$version" >"$INSTALL_DIR/version.txt"
    rm -rf "$tmpdir"
    return 0
}

do_install() {
    local version
    version=$(latest_version)
    info "准备安装 rustdesk-server ${version}"
    if is_installed; then
        warn "检测到已有安装,将先停止服务;密钥与数据库会保留"
        stop_services
    fi
    deploy_binaries "$version" || return 1
    write_units
    systemctl enable "$HBBS_SERVICE" "$HBBR_SERVICE" >/dev/null 2>&1
    start_services

    # hbbs 首次启动会在工作目录生成密钥对,稍等片刻再读公钥
    local i
    for i in $(seq 1 10); do
        [[ -f "$INSTALL_DIR/id_ed25519.pub" ]] && break
        sleep 1
    done

    echo
    ok "安装完成 (版本 ${version})"
    do_key
    local ip
    ip=$(public_ip)
    [[ -n "$ip" ]] && { c_green "公网 IP:"; echo "$ip"; echo; }
    warn "云厂商安全组 / 防火墙需放行: TCP 21115-21119 与 UDP 21116"
    echo "  ufw 示例:        ufw allow 21115:21119/tcp && ufw allow 21116/udp"
    echo "  firewalld 示例:  firewall-cmd --permanent --add-port=21115-21119/tcp --add-port=21116/udp && firewall-cmd --reload"
    echo
    echo "客户端配置(设置 → 网络): ID 服务器与中继服务器都填本机 IP/域名,API 服务器留空,密钥填上面的公钥"
}

do_upgrade() {
    if ! is_installed; then
        err "尚未安装,请先安装"
        return 1
    fi
    local cur latest
    cur=$(installed_version)
    latest=$(latest_version)
    info "当前版本: ${cur:-未知}    最新版本: ${latest}"
    if [[ "$cur" == "$latest" ]]; then
        ok "已经是最新版,无需升级"
        return 0
    fi
    info "升级中(密钥与数据库保留)..."
    stop_services
    if deploy_binaries "$latest"; then
        start_services
        ok "升级完成: ${cur:-未知} -> ${latest}"
    else
        err "升级失败,尝试恢复启动旧版本服务"
        start_services
        return 1
    fi
}

# ----------------------------- 卸载 ------------------------------------------
do_uninstall() {
    if ! is_installed && [[ ! -d "$INSTALL_DIR" ]]; then
        warn "未检测到安装,无需卸载"
        return 0
    fi
    read -rp "确认卸载 rustdesk-server?(y/N): " c
    [[ "$c" == "y" || "$c" == "Y" ]] || { info "已取消"; return 0; }

    read -rp "是否先备份密钥与数据库到 /root/rustdesk-backup?(Y/n): " b
    if [[ "$b" != "n" && "$b" != "N" && -d "$INSTALL_DIR" ]]; then
        local bak="/root/rustdesk-backup-$(date +%Y%m%d%H%M%S)"
        mkdir -p "$bak"
        cp -a "$INSTALL_DIR"/id_ed25519* "$bak/" 2>/dev/null || true
        cp -a "$INSTALL_DIR"/db.sqlite3* "$bak/" 2>/dev/null || true
        ok "已备份到 $bak"
    fi

    stop_services
    systemctl disable "$HBBS_SERVICE" "$HBBR_SERVICE" 2>/dev/null || true
    rm -f "$UNIT_DIR/${HBBS_SERVICE}.service" "$UNIT_DIR/${HBBR_SERVICE}.service"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR"
    ok "已卸载"
}

# ----------------------------- 状态 / 密钥 -----------------------------------
do_status() {
    echo
    info "hbbs: $(systemctl is-active "$HBBS_SERVICE" 2>/dev/null || echo unknown)"
    info "hbbr: $(systemctl is-active "$HBBR_SERVICE" 2>/dev/null || echo unknown)"
    echo
    info "监听端口:"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -E ':(21115|21116|21117|21118|21119)\b' || echo "  (无监听,服务可能未运行)"
    else
        netstat -tuln 2>/dev/null | grep -E ':(21115|21116|21117|21118|21119)\b' || echo "  (无监听,服务可能未运行)"
    fi
}

do_key() {
    echo
    if [[ -f "$INSTALL_DIR/id_ed25519.pub" ]]; then
        c_blue "服务器公钥 (Key):"
        cat "$INSTALL_DIR/id_ed25519.pub"
        echo
    else
        warn "未找到公钥文件。服务首次启动时 hbbs 会自动生成 $INSTALL_DIR/id_ed25519.pub,请确认服务正在运行"
    fi
}

public_ip() {
    local ip=""
    ip=$(wget -qO- --timeout=8 https://ipinfo.io/ip 2>/dev/null) || true
    if [[ -z "$ip" ]] && command -v curl >/dev/null 2>&1; then
        ip=$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null) || true
    fi
    echo "$ip"
}

# ----------------------------- 服务控制 --------------------------------------
do_start()   { is_installed || { err "尚未安装"; return 1; }; start_services; ok "服务已启动"; }
do_stop()    { stop_services; warn "服务已停止"; }
do_restart() { is_installed || { err "尚未安装"; return 1; }; stop_services; start_services; ok "服务已重启"; }

# ----------------------------- 脚本自更新 ------------------------------------
do_update_self() {
    local tmp
    tmp=$(mktemp)
    info "下载最新版脚本..."
    if download "$SCRIPT_RAW_URL" "$tmp"; then
        if bash -n "$tmp" 2>/dev/null; then
            install -m 0755 "$tmp" "$0"
            rm -f "$tmp"
            ok "脚本已更新,重新启动"
            exec bash "$0"
        fi
        err "下载的脚本语法校验未通过,已放弃更新"
        rm -f "$tmp"
        return 1
    fi
    err "脚本下载失败"
    rm -f "$tmp"
    return 1
}

# ----------------------------- 菜单 / 入口 -------------------------------------
show_menu() {
    clear 2>/dev/null || true
    c_green "# RustDesk Server 一键管理脚本"
    c_green "# Repo: https://github.com/signyf/rustdesk-server-tool"
    echo
    local ver
    ver=$(installed_version)
    c_blue "服务器版本: ${ver:-未安装}"
    c_blue "服务状态:   [$(status_text)]"
    echo
    c_blue ">~~~~~~~~~~~~~ rustdesk-server tool ~~~~~~~~~~~~~<"
    echo
    echo "  1: 安装            2: 卸载"
    echo
    echo "  3: 查看状态        4: 查看 Key"
    echo
    echo "  5: 启动服务        6: 停止服务"
    echo
    echo "  7: 重启服务        8: 升级服务端"
    echo
    echo "  9: 更新脚本        q: 退出"
    echo
}

main() {
    require_root
    require_systemd

    # 子命令模式(便于自动化/远程执行)
    case "${1:-}" in
        install)     ensure_tools; do_install ;;
        uninstall)   do_uninstall ;;
        status)      do_status ;;
        key)         do_key ;;
        start)       do_start ;;
        stop)        do_stop ;;
        restart)     do_restart ;;
        upgrade)     ensure_tools; do_upgrade ;;
        update-self) do_update_self ;;
        "")          : ;;  # 无参数走菜单
        *)
            err "未知命令: $1"
            echo "可用命令: install | uninstall | status | key | start | stop | restart | upgrade | update-self"
            exit 1
            ;;
    esac
    [[ -n "${1:-}" ]] && return 0

    ensure_tools
    while true; do
        show_menu
        read -rp "请输入命令号: " number || exit 0
        case "$number" in
            1) do_install ;;
            2) do_uninstall ;;
            3) do_status ;;
            4) do_key ;;
            5) do_start ;;
            6) do_stop ;;
            7) do_restart ;;
            8) do_upgrade ;;
            9) do_update_self ;;
            q | Q) echo; exit 0 ;;
            *) err "输入有误" ;;
        esac
        pause_back
    done
}

main "$@"
