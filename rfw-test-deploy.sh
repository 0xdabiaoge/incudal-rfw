#!/usr/bin/env bash
# ============================================================================
# RFW test deployment script
#
# This script mirrors the RFW deployment path used by the Incudal host installer:
# download a prebuilt GitHub Release binary, install it under /root/rfw, create a
# systemd service, and start RFW on the selected host interface.
# ============================================================================
set -euo pipefail

readonly SCRIPT_VERSION="0.1.0"
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
RFW test deployment script v${SCRIPT_VERSION}

Usage:
  sudo bash rfw-test-deploy.sh [options]
  sudo bash rfw-test-deploy.sh --uninstall
  sudo bash rfw-test-deploy.sh --status
  sudo bash rfw-test-deploy.sh --logs

Install options:
  --iface <IFACE>             Network interface to attach XDP to.
  --binary-url <URL>          Download this exact RFW binary.
  --release-url <URL>         Release download base URL.
                              Default: ${DEFAULT_RELEASE_URL}
  --rules "<ARGS>"            Raw RFW rule arguments. Overrides default rules.
                              Example: --rules "--countries CN --block-http"
  --no-default-rules          Install with no rule arguments unless --rules is set.
  --profile <PROFILE>         Rule profile: strong, hy2, tuic, tcp-node, baseline, manual.
                              Default: strong in --yes mode, interactive otherwise.
  --countries <LIST>          Country list for default rules. Default: CN.
  --geo-mode <blacklist|whitelist|none>
                              Geo mode for default rules. Default: blacklist.
  --log-port-access           Add --log-port-access to generated rules.
  --xdp-mode <auto|skb|drv|hw>
                              XDP attach mode. Default: auto.
  --force                     Reinstall without confirmation.
  --yes                       Non-interactive mode.

Actions:
  --uninstall                 Stop and remove the RFW test deployment.
  --status                    Show service status and installed command.
  --logs                      Show recent systemd logs.

Examples:
  sudo bash rfw-test-deploy.sh --iface eth0 --yes
  sudo bash rfw-test-deploy.sh --iface eth0 --profile hy2 --geo-mode none
  sudo bash rfw-test-deploy.sh --iface eth0 --xdp-mode skb --log-port-access
  sudo bash rfw-test-deploy.sh --binary-url https://example.com/rfw-x86_64-unknown-linux-musl --iface eth0
  sudo bash rfw-test-deploy.sh --iface eth0 --rules "--block-all-from CN --log-port-access"
EOF
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        error "Please run as root: sudo bash $0"
        exit 1
    fi
}

require_command() {
    local name="$1"
    if ! command -v "$name" >/dev/null 2>&1; then
        error "Missing required command: ${name}"
        exit 1
    fi
}

require_arg_value() {
    local flag="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "Missing value for ${flag}"
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
    [[ "${answer:-}" =~ ^[yY]$ ]]
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
            error "Unsupported architecture: $(uname -m). Supported: x86_64, aarch64."
            exit 1
            ;;
    esac
}

choose_iface() {
    if [[ -n "$IFACE" ]]; then
        if ! ip link show "$IFACE" >/dev/null 2>&1; then
            error "Network interface does not exist: ${IFACE}"
            exit 1
        fi
        return 0
    fi

    local default_iface=""
    default_iface=$(ip route show default 2>/dev/null | awk '/dev/ {for (i=1; i<=NF; i++) if ($i=="dev") print $(i+1)}' | head -n1 || true)
    if [[ -n "$default_iface" && "$NON_INTERACTIVE" == "true" ]]; then
        IFACE="$default_iface"
        info "Using default route interface: ${IFACE}"
        return 0
    fi

    local interfaces=()
    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        interfaces+=("$iface")
    done < <(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -v '^lo$')

    if [[ "${#interfaces[@]}" -eq 0 ]]; then
        error "No usable network interface found."
        exit 1
    fi

    if [[ "${#interfaces[@]}" -eq 1 ]]; then
        IFACE="${interfaces[0]}"
        info "Only one interface found, using: ${IFACE}"
        return 0
    fi

    if [[ -n "$default_iface" ]]; then
        echo -e "  ${DIM}Default route interface: ${default_iface}${NC}"
    fi

    echo ""
    echo "Available network interfaces:"
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
        echo -ne "${BOLD}Select interface [1-${#interfaces[@]}]: ${NC}"
        local choice=""
        read -r choice || true
        if [[ "${choice:-}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#interfaces[@]} )); then
            IFACE="${interfaces[$((choice - 1))]}"
            return 0
        fi
        warn "Invalid selection."
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
    [[ "$answer" =~ ^[yY]$ ]]
}

select_rule_profile() {
    if [[ -n "$RULE_PROFILE" || "$NON_INTERACTIVE" == "true" ]]; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}Rule profiles:${NC}"
    echo -e "  ${CYAN}1)${NC} strong   ${DIM}Block QUIC, HY2, TUIC, VLESS, VMess, UDP-FET, SOCKS, WG, HTTP, Email${NC}"
    echo -e "  ${CYAN}2)${NC} hy2      ${DIM}Focus HY2/obfs HY2 and UDP abuse, less broad than --block-quic${NC}"
    echo -e "  ${CYAN}3)${NC} tuic     ${DIM}Focus TUIC/QUIC proxy on non-web ports${NC}"
    echo -e "  ${CYAN}4)${NC} tcp-node ${DIM}Focus VLESS/VMess/SOCKS/FET weak TCP node protocols${NC}"
    echo -e "  ${CYAN}5)${NC} baseline ${DIM}Original broad node baseline without separated rules${NC}"
    echo -e "  ${CYAN}6)${NC} manual   ${DIM}Choose every rule interactively${NC}"
    echo ""

    while true; do
        echo -ne "${BOLD}Select rule profile [1-6, default 1]: ${NC}"
        local choice=""
        read -r choice || true
        case "${choice:-1}" in
            1) RULE_PROFILE="strong"; return 0 ;;
            2) RULE_PROFILE="hy2"; return 0 ;;
            3) RULE_PROFILE="tuic"; return 0 ;;
            4) RULE_PROFILE="tcp-node"; return 0 ;;
            5) RULE_PROFILE="baseline"; return 0 ;;
            6) RULE_PROFILE="manual"; return 0 ;;
            *) warn "Invalid selection." ;;
        esac
    done
}

build_manual_rules() {
    RFW_ARGS=""

    prompt_yes_no "Block Email/SMTP abuse?" "yes" && RFW_ARGS="${RFW_ARGS} --block-email"
    prompt_yes_no "Block HTTP plaintext inbound?" "yes" && RFW_ARGS="${RFW_ARGS} --block-http"
    prompt_yes_no "Block SOCKS4/SOCKS5 inbound?" "yes" && RFW_ARGS="${RFW_ARGS} --block-socks5"
    prompt_yes_no "Block TCP fully encrypted traffic, strict FET?" "yes" && RFW_ARGS="${RFW_ARGS} --block-fet-strict"
    prompt_yes_no "Block WireGuard inbound?" "yes" && RFW_ARGS="${RFW_ARGS} --block-wireguard"
    prompt_yes_no "Block all identifiable QUIC?" "yes" && RFW_ARGS="${RFW_ARGS} --block-quic"
    prompt_yes_no "Block Hysteria2/HY2 best-effort?" "yes" && RFW_ARGS="${RFW_ARGS} --block-hysteria2"
    prompt_yes_no "Block TUIC best-effort?" "yes" && RFW_ARGS="${RFW_ARGS} --block-tuic"
    prompt_yes_no "Block UDP high-entropy encrypted traffic?" "yes" && RFW_ARGS="${RFW_ARGS} --block-udp-fet"
    prompt_yes_no "Block raw VLESS over TCP?" "yes" && RFW_ARGS="${RFW_ARGS} --block-vless-tcp"
    prompt_yes_no "Block raw VMess over TCP?" "yes" && RFW_ARGS="${RFW_ARGS} --block-vmess-tcp"

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
                error "Invalid --profile: ${RULE_PROFILE}. Expected strong, hy2, tuic, tcp-node, baseline, or manual."
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
                    error "--geo-mode whitelist requires --countries."
                    exit 1
                fi
                RFW_ARGS="${RFW_ARGS} --allow-only-countries ${COUNTRIES}"
                ;;
            none)
                ;;
            *)
                error "Invalid --geo-mode: ${GEO_MODE}. Expected blacklist, whitelist, or none."
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
            error "Invalid --binary-url: ${BINARY_URL}"
            exit 1
        fi
        echo "$BINARY_URL"
        return 0
    fi

    if ! is_http_url "$RELEASE_URL"; then
        error "Invalid --release-url: ${RELEASE_URL}"
        exit 1
    fi

    local arch_suffix=""
    arch_suffix=$(detect_arch_suffix)
    echo "${RELEASE_URL%/}/rfw-${arch_suffix}-unknown-linux-musl"
}

stop_existing_service() {
    if systemctl list-unit-files "${RFW_SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${RFW_SERVICE_NAME}.service"; then
        info "Stopping existing ${RFW_SERVICE_NAME} service..."
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
        info "Downloading RFW binary, attempt ${attempt}: ${url}"
        if curl -fL --connect-timeout 15 --max-time 180 "$url" -o "$tmp_file"; then
            mv "$tmp_file" "$RFW_BIN_PATH"
            chmod +x "$RFW_BIN_PATH"
            log "RFW binary installed to ${RFW_BIN_PATH}"
            return 0
        fi
        warn "Download failed on attempt ${attempt}."
        [[ "$attempt" -lt 3 ]] && sleep 3
    done

    rm -f "$tmp_file" 2>/dev/null || true
    error "Failed to download RFW binary after 3 attempts."
    exit 1
}

write_service() {
    local exec_start=""
    exec_start=$(build_exec_start)

    cat > "$RFW_SERVICE_FILE" <<EOF
[Unit]
Description=RFW Test Firewall Service
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
    log "systemd service written to ${RFW_SERVICE_FILE}"
}

show_summary() {
    divider
    echo -e "${BOLD}RFW test deployment${NC}"
    echo "  Binary : ${RFW_BIN_PATH}"
    echo "  Service: ${RFW_SERVICE_FILE}"
    echo "  Iface  : ${IFACE}"
    echo "  XDP    : ${XDP_MODE}"
    echo "  Rules  : ${RFW_ARGS:-<none>}"
    divider
}

install_rfw() {
    require_root
    require_command curl
    require_command ip
    require_command systemctl

    step "Preparing RFW test deployment"

    if [[ -f "$RFW_BIN_PATH" || -f "$RFW_SERVICE_FILE" ]]; then
        if ! confirm "RFW appears to be installed. Reinstall?"; then
            info "Canceled."
            return 0
        fi
    fi

    choose_iface
    build_default_rules

    if [[ "$NON_INTERACTIVE" != "true" && "$FORCE" != "true" ]]; then
        show_summary
        if ! confirm "Install with this configuration?"; then
            info "Canceled."
            return 0
        fi
    fi

    stop_existing_service

    local url=""
    url=$(resolve_binary_url)
    step "Downloading binary"
    download_binary "$url"

    step "Installing service"
    write_service

    step "Starting service"
    systemctl start "$RFW_SERVICE_NAME"
    systemctl enable "$RFW_SERVICE_NAME" >/dev/null 2>&1 || true

    sleep 2
    if systemctl is-active --quiet "$RFW_SERVICE_NAME"; then
        log "RFW service is running."
        show_summary
        echo -e "${DIM}Logs: sudo journalctl -u ${RFW_SERVICE_NAME} -f${NC}"
        if [[ "$RFW_ARGS" == *"--log-port-access"* ]]; then
            echo -e "${DIM}Stats: sudo ${RFW_BIN_PATH} stats${NC}"
        fi
    else
        error "RFW service failed to start."
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
        warn "RFW test deployment is not installed."
        return 0
    fi

    if ! confirm "Remove RFW test deployment?"; then
        info "Canceled."
        return 0
    fi

    step "Removing RFW test deployment"
    systemctl stop "$RFW_SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$RFW_SERVICE_NAME" 2>/dev/null || true
    rm -f "$RFW_SERVICE_FILE" 2>/dev/null || true
    rm -f /usr/lib/systemd/system/${RFW_SERVICE_NAME}.service 2>/dev/null || true
    rm -f /lib/systemd/system/${RFW_SERVICE_NAME}.service 2>/dev/null || true
    rm -rf "$RFW_INSTALL_DIR" 2>/dev/null || true
    rm -f /sys/fs/bpf/rfw_port_access_log 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log "RFW test deployment removed."
}

show_status() {
    require_command systemctl

    divider
    echo -e "${BOLD}RFW status${NC}"
    if [[ -x "$RFW_BIN_PATH" ]]; then
        echo "  Binary : ${RFW_BIN_PATH}"
    else
        echo "  Binary : not installed"
    fi

    if [[ -f "$RFW_SERVICE_FILE" ]]; then
        echo "  Service: ${RFW_SERVICE_FILE}"
        local exec_start=""
        exec_start=$(grep '^ExecStart=' "$RFW_SERVICE_FILE" 2>/dev/null || true)
        echo "  Command: ${exec_start#ExecStart=}"
    else
        echo "  Service: not installed"
    fi

    local status="unknown"
    status=$(systemctl is-active "$RFW_SERVICE_NAME" 2>/dev/null || true)
    echo "  State  : ${status:-unknown}"
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
                error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$XDP_MODE" in
        auto|skb|drv|driver|hw|hardware) ;;
        *)
            error "Invalid --xdp-mode: ${XDP_MODE}"
            exit 1
            ;;
    esac

    case "$RULE_PROFILE" in
        ""|strong|hy2|tuic|tcp-node|baseline|manual) ;;
        *)
            error "Invalid --profile: ${RULE_PROFILE}"
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
            error "Unknown action: ${ACTION}"
            exit 1
            ;;
    esac
}

main "$@"
