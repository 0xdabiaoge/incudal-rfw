#!/usr/bin/env bash
# ============================================================================
# RFW 测试部署脚本
#
# 本脚本用于复刻 Incudal 宿主机安装器的 RFW 部署路径：
# 从 GitHub Release 下载预编译二进制，安装到 /root/rfw，写入 systemd
# 服务，并在选定网卡上启动 RFW。
# ============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="0.1.1"
readonly DEFAULT_RELEASE_URL="https://github.com/0xdabiaoge/incudal-rfw/releases/latest/download"
readonly RFW_INSTALL_DIR="/root/rfw"
readonly RFW_BIN_PATH="${RFW_INSTALL_DIR}/rfw"
readonly RFW_SERVICE_NAME="rfw"
readonly RFW_SERVICE_FILE="/etc/systemd/system/${RFW_SERVICE_NAME}.service"

readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[1;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

ACTION="install"
IFACE=""
RFW_ARGS=""
BINARY_URL=""
RELEASE_URL="$DEFAULT_RELEASE_URL"
XDP_MODE="auto"
ENABLE_DEFAULT_RULES="true"
COUNTRIES="CN"
GEO_MODE="blacklist"
LOG_PORT_ACCESS="false"
FORCE="false"
NON_INTERACTIVE="false"
SHOW_LOGS_ON_FAILURE="true"
RULE_PROFILE=""

log() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; }
step() { echo -e "\n${CYAN}[>]${NC} ${BOLD}$1${NC}"; }

divider() {
    echo -e "${DIM}------------------------------------------------------------${NC}"
}

usage() {
    cat <<EOF
RFW 测试部署脚本 v${SCRIPT_VERSION}

用法：
  sudo bash rfw-test-deploy.sh [参数]
  sudo bash rfw-test-deploy.sh --uninstall
  sudo bash rfw-test-deploy.sh --status
  sudo bash rfw-test-deploy.sh --logs

安装参数：
  --iface <网卡名>            指定要挂载 XDP 的网卡。
  --binary-url <URL>          指定完整的 RFW 二进制下载地址。
  --release-url <URL>         指定 Release 下载基础地址。
                              默认：${DEFAULT_RELEASE_URL}
  --rules "<参数>"            直接传入原始 RFW 规则参数，会覆盖默认规则。
                              示例：--rules "--countries CN --block-http"
  --no-default-rules          不生成默认规则；除非同时指定 --rules。
  --profile <配置>            规则配置：strong、hy2、tuic、tcp-node、baseline、manual。
                              --yes 模式默认 strong；交互模式会询问。
  --countries <列表>          默认规则使用的国家代码列表，默认：CN。
  --geo-mode <blacklist|whitelist|none>
                              默认规则的 GeoIP 模式，默认：blacklist。
  --log-port-access           在生成规则中加入 --log-port-access。
  --xdp-mode <auto|skb|drv|hw>
                              XDP 挂载模式，默认：auto。
  --force                     不再确认，直接重装。
  --yes                       非交互模式。

操作：
  --uninstall                 停止并移除 RFW 测试部署。
  --status                    查看服务状态和已安装命令。
  --logs                      查看最近的 systemd 日志。

示例：
  sudo bash rfw-test-deploy.sh --iface eth0 --yes
  sudo bash rfw-test-deploy.sh --iface eth0 --profile hy2 --geo-mode none
  sudo bash rfw-test-deploy.sh --iface eth0 --xdp-mode skb --log-port-access
  sudo bash rfw-test-deploy.sh --binary-url https://example.com/rfw-x86_64-unknown-linux-musl --iface eth0
  sudo bash rfw-test-deploy.sh --iface eth0 --rules "--block-all-from CN --log-port-access"
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "请使用 root 权限运行：sudo bash $0"
        exit 1
    fi
}

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        error "缺少必要命令：${name}"
        exit 1
    fi
}

require_arg_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "${flag} 缺少参数值"
        exit 1
    fi
}

is_http_url() {
    local value="${1:-}"
    [[ "$value" =~ ^https?://[^[:space:]]+$ ]]
}

confirm() {
    local prompt="$1"
    if [[ "$FORCE" == "true" || "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi

    echo -ne "${YELLOW}${prompt}${NC} [y/N]: "
    local answer=""
    read -r answer || true
    [[ "${answer:-}" =~ ^([yY]|[yY][eE][sS]|是)$ ]]
}

detect_arch_suffix() {
    case "$(uname -m)" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            error "不支持当前架构：$(uname -m)。目前支持：x86_64、aarch64。"
            exit 1
            ;;
    esac
}

choose_iface() {
    if [[ -n "$IFACE" ]]; then
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            error "网卡不存在：${IFACE}"
            exit 1
        fi
        return 0
    fi

    local default_iface=""
    default_iface=$(ip route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}' | head -n1 || true)
    if [[ -n "$default_iface" && "$NON_INTERACTIVE" == "true" ]]; then
        IFACE="$default_iface"
        info "使用默认路由网卡：${IFACE}"
        return 0
    fi

    local interfaces=()
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        interfaces+=("$iface")
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$')

    if [[ "${#interfaces[@]}" -eq 0 ]]; then
        error "没有找到可用网卡。"
        exit 1
    fi

    if [[ "${#interfaces[@]}" -eq 1 ]]; then
        IFACE="${interfaces[0]}"
        info "只找到一个可用网卡，自动使用：${IFACE}"
        return 0
    fi

    if [[ -n "$default_iface" ]]; then
        echo -e "  ${DIM}默认路由网卡：${default_iface}${NC}"
    fi

    echo ""
    echo "可用网卡："
    local i
    for i in "${!interfaces[@]}"; do
        local num=$((i + 1))
        local iface_ip=""
        iface_ip=$(ip -4 addr show "${interfaces[$i]}" 2>/dev/null | awk '/inet / {print $2}' | head -n1 || true)
        if [[ -n "$iface_ip" ]]; then
            echo -e "  ${CYAN}${num})${NC} ${interfaces[$i]} ${DIM}(${iface_ip})${NC}"
        else
            echo -e "  ${CYAN}${num})${NC} ${interfaces[$i]}"
        fi
    done
    echo ""

    while true; do
        echo -ne "${BOLD}请选择网卡 [1-${#interfaces[@]}]：${NC}"
        local choice=""
        read -r choice || true
        if [[ "${choice:-}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
            IFACE="${interfaces[$((choice - 1))]}"
            return 0
        fi
        warn "选择无效，请重新输入。"
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default_answer="$2"
    local hint="[y/N]"
    if [[ "$default_answer" == "yes" ]]; then
        hint="[Y/n]"
    fi

    echo -ne "${BOLD}${prompt}${NC} ${hint}: "
    local answer=""
    read -r answer || true
    if [[ -z "${answer:-}" ]]; then
        [[ "$default_answer" == "yes" ]]
        return
    fi
    [[ "$answer" =~ ^([yY]|[yY][eE][sS]|是)$ ]]
}

select_rule_profile() {
    if [[ -n "$RULE_PROFILE" || "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}规则配置：${NC}"
    echo -e "  ${CYAN}1)${NC} strong   ${DIM}强力阻断：QUIC、HY2、TUIC、VLESS、VMess、UDP-FET、SOCKS、WG、HTTP、Email 全开${NC}"
    echo -e "  ${CYAN}2)${NC} hy2      ${DIM}重点测试 HY2 / 混淆 HY2 / UDP 滥用，比 --block-quic 更克制${NC}"
    echo -e "  ${CYAN}3)${NC} tuic     ${DIM}重点测试 TUIC / 非 Web 端口 QUIC 代理${NC}"
    echo -e "  ${CYAN}4)${NC} tcp-node ${DIM}重点测试 VLESS、VMess、SOCKS、FET 这类 TCP 弱节点协议${NC}"
    echo -e "  ${CYAN}5)${NC} baseline ${DIM}基础节点阻断组合，不启用 HY2/TUIC 拆分规则${NC}"
    echo -e "  ${CYAN}6)${NC} manual   ${DIM}逐条规则手动选择${NC}"
    echo ""

    while true; do
        echo -ne "${BOLD}请选择规则配置 [1-6，默认 1]：${NC}"
        local choice=""
        read -r choice || true
        case "${choice:-1}" in
            1) RULE_PROFILE="strong"; return 0 ;;
            2) RULE_PROFILE="hy2"; return 0 ;;
            3) RULE_PROFILE="tuic"; return 0 ;;
            4) RULE_PROFILE="tcp-node"; return 0 ;;
            5) RULE_PROFILE="baseline"; return 0 ;;
            6) RULE_PROFILE="manual"; return 0 ;;
            *) warn "选择无效，请重新输入。" ;;
        esac
    done
}

build_manual_rules() {
    RFW_ARGS=""

    prompt_yes_no "是否阻断 Email/SMTP 发信滥用？" "yes" && RFW_ARGS="${RFW_ARGS} --block-email"
    prompt_yes_no "是否阻断明文 HTTP 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-http"
    prompt_yes_no "是否阻断 SOCKS4/SOCKS5 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-socks5"
    prompt_yes_no "是否阻断 TCP 全加密高熵流量（严格 FET）？" "yes" && RFW_ARGS="${RFW_ARGS} --block-fet-strict"
    prompt_yes_no "是否阻断 WireGuard 入站？" "yes" && RFW_ARGS="${RFW_ARGS} --block-wireguard"
    prompt_yes_no "是否阻断所有可识别 QUIC？" "yes" && RFW_ARGS="${RFW_ARGS} --block-quic"
    prompt_yes_no "是否尽力阻断 Hysteria2/HY2？" "yes" && RFW_ARGS="${RFW_ARGS} --block-hysteria2"
    prompt_yes_no "是否尽力阻断 TUIC？" "yes" && RFW_ARGS="${RFW_ARGS} --block-tuic"
    prompt_yes_no "是否阻断 UDP 高熵加密流量？" "yes" && RFW_ARGS="${RFW_ARGS} --block-udp-fet"
    prompt_yes_no "是否阻断裸 VLESS over TCP？" "yes" && RFW_ARGS="${RFW_ARGS} --block-vless-tcp"
    prompt_yes_no "是否阻断裸 VMess over TCP？" "yes" && RFW_ARGS="${RFW_ARGS} --block-vmess-tcp"

    RFW_ARGS="${RFW_ARGS# }"
}

build_default_rules() {
    if [[ -n "$RFW_ARGS" ]]; then
        if [[ "$LOG_PORT_ACCESS" == "true" && "$RFW_ARGS" != *"--log-port-access"* ]]; then
            RFW_ARGS="${RFW_ARGS} --log-port-access"
        fi
        return 0
    fi

    COUNTRIES=$(printf '%s' "$COUNTRIES" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

    if [[ "$ENABLE_DEFAULT_RULES" != "true" ]]; then
        RFW_ARGS=""
    else
        select_rule_profile
        RULE_PROFILE="${RULE_PROFILE:-strong}"

        case "$RULE_PROFILE" in
            strong)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-wireguard --block-quic --block-hysteria2 --block-tuic --block-udp-fet --block-vless-tcp --block-vmess-tcp"
                ;;
            hy2)
                RFW_ARGS="--block-email --block-socks5 --block-fet-strict --block-wireguard --block-hysteria2 --block-udp-fet"
                ;;
            tuic)
                RFW_ARGS="--block-email --block-socks5 --block-wireguard --block-tuic"
                ;;
            tcp-node)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-vless-tcp --block-vmess-tcp"
                ;;
            baseline)
                RFW_ARGS="--block-email --block-http --block-socks5 --block-fet-strict --block-wireguard"
                ;;
            manual)
                build_manual_rules
                ;;
            *)
                error "--profile 无效：${RULE_PROFILE}。可选值：strong、hy2、tuic、tcp-node、baseline、manual。"
                exit 1
                ;;
        esac

        case "$GEO_MODE" in
            blacklist)
                if [[ -n "$COUNTRIES" ]]; then
                    RFW_ARGS="${RFW_ARGS} --countries ${COUNTRIES}"
                fi
                ;;
            whitelist)
                if [[ -z "$COUNTRIES" ]]; then
                    error "--geo-mode whitelist 必须同时指定 --countries。"
                    exit 1
                fi
                RFW_ARGS="${RFW_ARGS} --allow-only-countries ${COUNTRIES}"
                ;;
            none)
                ;;
            *)
                error "--geo-mode 无效：${GEO_MODE}。可选值：blacklist、whitelist、none。"
                exit 1
                ;;
        esac
    fi

    if [[ "$LOG_PORT_ACCESS" == "true" ]]; then
        RFW_ARGS="${RFW_ARGS} --log-port-access"
    fi
}

systemd_escape_arg() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "$value"
}

build_exec_start() {
    local command=""
    command="$(systemd_escape_arg "$RFW_BIN_PATH")"
    command+=" --iface $(systemd_escape_arg "$IFACE")"
    command+=" --xdp-mode $(systemd_escape_arg "$XDP_MODE")"
    if [[ -n "$RFW_ARGS" ]]; then
        command+=" ${RFW_ARGS}"
    fi
    printf '%s\n' "$command"
}

resolve_binary_url() {
    if [[ -n "$BINARY_URL" ]]; then
        if ! is_http_url "$BINARY_URL"; then
            error "--binary-url 无效：${BINARY_URL}"
            exit 1
        fi
        echo "$BINARY_URL"
        return 0
    fi

    if ! is_http_url "$RELEASE_URL"; then
        error "--release-url 无效：${RELEASE_URL}"
        exit 1
    fi

    local arch_suffix=""
    arch_suffix=$(detect_arch_suffix)
    echo "${RELEASE_URL%/}/rfw-${arch_suffix}-unknown-linux-musl"
}

stop_existing_service() {
    if systemctl list-unit-files "${RFW_SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${RFW_SERVICE_NAME}.service"; then
        info "正在停止已有 ${RFW_SERVICE_NAME} 服务..."
        systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    fi
}

download_binary() {
    local url="$1"

    mkdir -p "$RFW_INSTALL_DIR"
    local tmp_file="${RFW_BIN_PATH}.download"
    rm -f "$tmp_file" 2>/dev/null || true

    local attempt
    for attempt in 1 2 3; do
        info "正在下载 RFW 二进制，第 ${attempt} 次尝试：${url}"
        if curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp_file"; then
            mv "$tmp_file" "$RFW_BIN_PATH"
            chmod +x "$RFW_BIN_PATH"
            log "RFW 二进制已安装到：${RFW_BIN_PATH}"
            return 0
        fi
        warn "第 ${attempt} 次下载失败。"
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    rm -f "$tmp_file" 2>/dev/null || true
    error "连续 3 次下载 RFW 二进制失败。"
    exit 1
}

write_service() {
    local exec_start=""
    exec_start=$(build_exec_start)

    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=RFW 测试防火墙服务
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=RUST_LOG=info
ExecStart=${exec_start}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "systemd 服务已写入：${RFW_SERVICE_FILE}"
}

show_summary() {
    divider
    echo -e "${BOLD}RFW 测试部署配置${NC}"
    echo "  二进制文件：${RFW_BIN_PATH}"
    echo "  服务文件  ：${RFW_SERVICE_FILE}"
    echo "  网卡      ：${IFACE}"
    echo "  XDP 模式  ：${XDP_MODE}"
    echo "  规则参数  ：${RFW_ARGS:-<无>}"
    divider
}

install_rfw() {
    require_root
    require_command curl
    require_command ip
    require_command systemctl

    step "准备 RFW 测试部署"

    if [[ -f "$RFW_BIN_PATH" || -f "$RFW_SERVICE_FILE" ]]; then
        if ! confirm "检测到 RFW 似乎已经安装，是否重新安装？"; then
            info "已取消。"
            return 0
        fi
    fi

    choose_iface
    build_default_rules

    if [[ "$NON_INTERACTIVE" != "true" && "$FORCE" != "true" ]]; then
        show_summary
        if ! confirm "确认使用以上配置进行安装？"; then
            info "已取消。"
            return 0
        fi
    fi

    stop_existing_service

    local url=""
    url=$(resolve_binary_url)
    step "下载二进制文件"
    download_binary "$url"

    step "安装 systemd 服务"
    write_service

    step "启动服务"
    systemctl start "$RFW_SERVICE_NAME"
    systemctl enable "$RFW_SERVICE_NAME" >/dev/null 2>&1 || true

    sleep 2
    if systemctl is-active --quiet "$RFW_SERVICE_NAME"; then
        log "RFW 服务正在运行。"
        show_summary
        echo -e "${DIM}查看实时日志：sudo journalctl -u ${RFW_SERVICE_NAME} -f${NC}"
        if [[ "$RFW_ARGS" == *"--log-port-access"* ]]; then
            echo -e "${DIM}查看统计：sudo ${RFW_BIN_PATH} stats${NC}"
        fi
    else
        error "RFW 服务启动失败。"
        if [[ "$SHOW_LOGS_ON_FAILURE" == "true" ]]; then
            journalctl -u "$RFW_SERVICE_NAME" -n 80 --no-pager 2>/dev/null || true
        fi
        exit 1
    fi
}

uninstall_rfw() {
    require_root
    require_command systemctl

    if [[ ! -f "$RFW_BIN_PATH" && ! -f "$RFW_SERVICE_FILE" ]]; then
        warn "当前没有安装 RFW 测试部署。"
        return 0
    fi

    if ! confirm "确认移除 RFW 测试部署？"; then
        info "已取消。"
        return 0
    fi

    step "移除 RFW 测试部署"
    systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    rm -f "$RFW_SERVICE_FILE" 2>/dev/null || true
    rm -f /usr/lib/systemd/system/${RFW_SERVICE_NAME}.service 2>/dev/null || true
    rm -f /lib/systemd/system/${RFW_SERVICE_NAME}.service 2>/dev/null || true
    rm -rf "$RFW_INSTALL_DIR" 2>/dev/null || true
    rm -f /sys/fs/bpf/rfw_port_access_log 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log "RFW 测试部署已移除。"
}

show_status() {
    require_command systemctl

    divider
    echo -e "${BOLD}RFW 状态${NC}"
    if [[ -x "$RFW_BIN_PATH" ]]; then
        echo "  二进制文件：${RFW_BIN_PATH}"
    else
        echo "  二进制文件：未安装"
    fi

    if [[ -f "$RFW_SERVICE_FILE" ]]; then
        echo "  服务文件  ：${RFW_SERVICE_FILE}"
        local exec_start=""
        exec_start=$(grep '^ExecStart=' "$RFW_SERVICE_FILE" 2>/dev/null || true)
        echo "  启动命令  ：${exec_start#ExecStart=}"
    else
        echo "  服务文件  ：未安装"
    fi

    local status="unknown"
    status=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
    if [[ -z "${status:-}" || "$status" == "unknown" ]]; then
        status="未知"
    fi
    echo "  运行状态  ：${status}"
    divider
}

show_logs() {
    require_command journalctl
    journalctl -u "$RFW_SERVICE_NAME" -n 120 --no-pager
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iface)
                require_arg_value "$1" "${2:-}"
                IFACE="$2"; shift 2 ;;
            --binary-url)
                require_arg_value "$1" "${2:-}"
                BINARY_URL="$2"; shift 2 ;;
            --release-url)
                require_arg_value "$1" "${2:-}"
                RELEASE_URL="$2"; shift 2 ;;
            --rules)
                require_arg_value "$1" "${2:-}"
                RFW_ARGS="$2"; ENABLE_DEFAULT_RULES="false"; shift 2 ;;
            --no-default-rules)
                ENABLE_DEFAULT_RULES="false"; shift ;;
            --profile)
                require_arg_value "$1" "${2:-}"
                RULE_PROFILE="$2"; shift 2 ;;
            --countries)
                require_arg_value "$1" "${2:-}"
                COUNTRIES="$2"; shift 2 ;;
            --geo-mode)
                require_arg_value "$1" "${2:-}"
                GEO_MODE="$2"; shift 2 ;;
            --log-port-access)
                LOG_PORT_ACCESS="true"; shift ;;
            --xdp-mode)
                require_arg_value "$1" "${2:-}"
                XDP_MODE="$2"; shift 2 ;;
            --force)
                FORCE="true"; shift ;;
            --yes|-y)
                NON_INTERACTIVE="true"; FORCE="true"; shift ;;
            --uninstall)
                ACTION="uninstall"; shift ;;
            --status)
                ACTION="status"; shift ;;
            --logs)
                ACTION="logs"; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                error "未知参数：$1"
                usage
                exit 1
                ;;
        esac
    done

    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *)
            error "--xdp-mode 无效：${XDP_MODE}"
            exit 1
            ;;
    esac

    case "$RULE_PROFILE" in
        ""|strong|hy2|tuic|tcp-node|baseline|manual) ;;
        *)
            error "--profile 无效：${RULE_PROFILE}"
            exit 1
            ;;
    esac
}

main() {
    parse_args "$@"

    case "$ACTION" in
        install)
            install_rfw ;;
        uninstall)
            uninstall_rfw ;;
        status)
            show_status ;;
        logs)
            show_logs ;;
        *)
            error "未知操作：${ACTION}"
            exit 1
            ;;
    esac
}

main "$@"
