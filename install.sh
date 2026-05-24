#!/bin/sh

set -u

NZ_BASE_PATH="${NZ_BASE_PATH:-/opt/nezha}"
NZ_DASHBOARD_PATH="${NZ_BASE_PATH}/dashboard"
NZ_AGENT_PATH="${NZ_BASE_PATH}/agent"
NZ_DASHBOARD_SERVICE="/etc/systemd/system/nezha-dashboard.service"
NZ_RELEASE_REPO="${NZ_RELEASE_REPO:-nezha-rs/nezha-rs}"
NZ_SCRIPT_URL="${NZ_SCRIPT_URL:-https://raw.githubusercontent.com/nezha-rs/scripts/main/install.sh}"
NZ_VERSION="${NZ_VERSION:-latest}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

warn() {
    printf "${yellow}%s${plain}\n" "$*"
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

println() {
    printf "%s\n" "$*"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        err "sudo is not installed. Run this script as root or install sudo."
        exit 1
    fi
}

check_debian() {
    if [ "${NZ_SKIP_DEBIAN_CHECK:-0}" = "1" ]; then
        return
    fi
    if [ ! -r /etc/os-release ]; then
        err "Cannot detect OS. This installer targets Debian 12 or newer."
        exit 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    debian_major="$(printf "%s" "${VERSION_ID:-0}" | awk -F. '{print $1}')"
    case "$debian_major" in
        ''|*[!0-9]*)
            debian_major=0
            ;;
    esac
    if [ "${ID:-}" != "debian" ] || [ "$debian_major" -lt 12 ]; then
        err "This installer targets Debian 12 or newer. Set NZ_SKIP_DEBIAN_CHECK=1 to bypass."
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        err "systemd is required."
        exit 1
    fi
}

install_deps() {
    info "> Install runtime dependencies"
    as_root apt-get update
    as_root apt-get install -y ca-certificates curl unzip coreutils
}

env_check() {
    mach="$(uname -m)"
    case "$mach" in
        amd64|x86_64)
            os_arch="amd64"
            ;;
        i386|i686)
            os_arch="386"
            ;;
        aarch64|arm64)
            os_arch="arm64"
            ;;
        armv5*|armv6*|armv7*|arm*)
            os_arch="arm"
            ;;
        s390x)
            os_arch="s390x"
            ;;
        riscv64)
            os_arch="riscv64"
            ;;
        loongarch64)
            os_arch="loong64"
            ;;
        *)
            err "Unknown architecture: $mach"
            exit 1
            ;;
    esac
}

init_common() {
    check_debian
    check_systemd
    env_check
}

prepare_download_env() {
    init_common
    install_deps
}

release_base_url() {
    if [ -z "$NZ_VERSION" ] || [ "$NZ_VERSION" = "latest" ]; then
        printf "https://github.com/%s/releases/latest/download" "$NZ_RELEASE_REPO"
    else
        printf "https://github.com/%s/releases/download/%s" "$NZ_RELEASE_REPO" "$NZ_VERSION"
    fi
}

download_file() {
    url="$1"
    output="$2"
    curl -fL --retry 3 --connect-timeout 15 --max-time 300 "$url" -o "$output"
}

download_checksums() {
    if [ -n "${NZ_CHECKSUMS_FILE:-}" ] && [ -f "$NZ_CHECKSUMS_FILE" ]; then
        return
    fi
    NZ_CHECKSUMS_FILE="${NZ_TMP_DIR}/checksums.txt"
    download_file "$(release_base_url)/checksums.txt" "$NZ_CHECKSUMS_FILE"
}

verify_checksum() {
    asset="$1"
    file="$2"
    download_checksums
    line="$(tr -d '\r' <"$NZ_CHECKSUMS_FILE" | awk -v asset="$asset" '$2 == asset {print $1 "  " $2; exit}')"
    if [ -z "$line" ]; then
        err "Checksum for $asset not found."
        exit 1
    fi
    printf "%s\n" "$line" >"${NZ_TMP_DIR}/${asset}.sha256"
    (
        cd "$(dirname "$file")" &&
        sha256sum -c "${NZ_TMP_DIR}/${asset}.sha256"
    )
}

download_asset() {
    asset="$1"
    output="$2"
    url="$(release_base_url)/${asset}"
    info "> Download $asset"
    download_file "$url" "$output"
    verify_checksum "$asset" "$output"
}

with_tmp_dir() {
    NZ_TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$NZ_TMP_DIR"' EXIT INT TERM
}

random_secret() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"
}

yaml_quote() {
    printf "%s" "$1" | sed "s/'/''/g; s/^/'/; s/$/'/"
}

get_yaml_value() {
    file="$1"
    key="$2"
    if [ -r "$file" ]; then
        awk -F: -v key="$key" '
        $1 == key {
            sub(/^[ \t]*/, "", $2)
            sub(/[ \t]*$/, "", $2)
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            gsub(/^'\''/, "", $2)
            gsub(/'\''$/, "", $2)
            print $2
            exit
        }
        ' "$file"
    elif command -v sudo >/dev/null 2>&1; then
        sudo awk -F: -v key="$key" '
        $1 == key {
            sub(/^[ \t]*/, "", $2)
            sub(/[ \t]*$/, "", $2)
            gsub(/^"/, "", $2)
            gsub(/"$/, "", $2)
            gsub(/^'\''/, "", $2)
            gsub(/'\''$/, "", $2)
            print $2
            exit
        }
        ' "$file" 2>/dev/null
    else
        return 1
    fi
}

get_env_value() {
    file="$1"
    key="$2"
    if [ -r "$file" ]; then
        awk -F= -v key="$key" '$1 == key {print $2; exit}' "$file"
    elif command -v sudo >/dev/null 2>&1; then
        sudo awk -F= -v key="$key" '$1 == key {print $2; exit}' "$file" 2>/dev/null
    else
        return 1
    fi
}

ask() {
    var="$1"
    prompt="$2"
    default="$3"
    eval "current=\${$var:-}"
    if [ -n "$current" ]; then
        eval "$var=\$current"
        return
    fi
    if [ -t 0 ]; then
        if [ -n "$default" ]; then
            printf "%s [%s]: " "$prompt" "$default"
        else
            printf "%s: " "$prompt"
        fi
        read -r answer
        [ -n "$answer" ] || answer="$default"
    else
        answer="$default"
    fi
    eval "$var=\$answer"
}

ask_bool() {
    var="$1"
    prompt="$2"
    default="$3"
    eval "current=\${$var:-}"
    if [ -n "$current" ]; then
        case "$current" in
            1|true|TRUE|yes|YES|y|Y) eval "$var=true" ;;
            *) eval "$var=false" ;;
        esac
        return
    fi
    if [ -t 0 ]; then
        if [ "$default" = "true" ]; then
            printf "%s [Y/n]: " "$prompt"
        else
            printf "%s [y/N]: " "$prompt"
        fi
        read -r answer
    else
        answer=""
    fi
    [ -n "$answer" ] || answer="$default"
    case "$answer" in
        1|true|TRUE|yes|YES|y|Y) eval "$var=true" ;;
        *) eval "$var=false" ;;
    esac
}

confirm_uninstall() {
    target="$1"
    if [ "${NZ_YES:-0}" = "1" ] || [ "${NZ_YES:-}" = "true" ]; then
        return 0
    fi
    if [ -t 0 ]; then
        printf "Proceed to uninstall %s? [y/N]: " "$target"
        read -r answer
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

dashboard_asset_name() {
    case "$os_arch" in
        amd64|arm64|s390x)
            printf "dashboard-linux-%s.zip" "$os_arch"
            ;;
        *)
            err "Dashboard release does not provide linux_${os_arch} binary."
            exit 1
            ;;
    esac
}

agent_asset_name() {
    printf "nezha-agent_linux_%s.zip" "$os_arch"
}

download_dashboard_binary() {
    asset="$(dashboard_asset_name)"
    zip_path="${NZ_TMP_DIR}/${asset}"
    extract_dir="${NZ_TMP_DIR}/dashboard"
    download_asset "$asset" "$zip_path"
    mkdir -p "$extract_dir"
    unzip -qo "$zip_path" -d "$extract_dir"
    [ -x "$extract_dir/nezha-dashboard" ] || chmod +x "$extract_dir/nezha-dashboard"
    [ -x "$extract_dir/nezha-dashboard" ] || {
        err "nezha-dashboard binary not found in $asset."
        exit 1
    }
    NZ_DOWNLOADED_DASHBOARD="$extract_dir/nezha-dashboard"
}

download_agent_binary() {
    asset="$(agent_asset_name)"
    zip_path="${NZ_TMP_DIR}/${asset}"
    extract_dir="${NZ_TMP_DIR}/agent"
    download_asset "$asset" "$zip_path"
    mkdir -p "$extract_dir"
    unzip -qo "$zip_path" -d "$extract_dir"
    [ -x "$extract_dir/nezha-agent" ] || chmod +x "$extract_dir/nezha-agent"
    [ -x "$extract_dir/nezha-agent" ] || {
        err "nezha-agent binary not found in $asset."
        exit 1
    }
    NZ_DOWNLOADED_AGENT="$extract_dir/nezha-agent"
}

install_dashboard_binary() {
    download_dashboard_binary
    as_root mkdir -p "$NZ_DASHBOARD_PATH"
    as_root install -m 0755 "$NZ_DOWNLOADED_DASHBOARD" "$NZ_DASHBOARD_PATH/app"
}

install_agent_binary() {
    download_agent_binary
    as_root mkdir -p "$NZ_AGENT_PATH"
    as_root install -m 0755 "$NZ_DOWNLOADED_AGENT" "$NZ_AGENT_PATH/nezha-agent"
}

dashboard_config_defaults() {
    config="$NZ_DASHBOARD_PATH/data/config.yaml"
    NZ_SITE_TITLE="${NZ_SITE_TITLE:-$(get_yaml_value "$config" site_name || true)}"
    NZ_HTTP_PORT="${NZ_HTTP_PORT:-$(get_yaml_value "$config" listen_port || true)}"
    NZ_INSTALL_HOST="${NZ_INSTALL_HOST:-$(get_yaml_value "$config" install_host || true)}"
    NZ_AGENT_TLS="${NZ_AGENT_TLS:-$(get_yaml_value "$config" tls || true)}"
    NZ_LANGUAGE="${NZ_LANGUAGE:-$(get_yaml_value "$config" language || true)}"
    NZ_AGENT_SECRET_KEY="${NZ_AGENT_SECRET_KEY:-$(get_yaml_value "$config" agent_secret_key || true)}"
    NZ_JWT_SECRET_KEY="${NZ_JWT_SECRET_KEY:-$(get_yaml_value "$config" jwt_secret_key || true)}"
}

write_dashboard_config() {
    dashboard_config_defaults
    ask NZ_SITE_TITLE "Site title" "Nezha"
    ask NZ_HTTP_PORT "Dashboard HTTP port" "8008"
    ask NZ_INSTALL_HOST "Public install host, e.g. https://nezha.example.com or example.com:443" ""
    ask_bool NZ_AGENT_TLS "Should agents connect to dashboard with TLS" "${NZ_AGENT_TLS:-false}"
    ask NZ_LANGUAGE "Backend language (zh_CN, zh_TW, en_US)" "en_US"
    NZ_AGENT_SECRET_KEY="${NZ_AGENT_SECRET_KEY:-$(random_secret 32)}"
    NZ_JWT_SECRET_KEY="${NZ_JWT_SECRET_KEY:-$(random_secret 96)}"

    tmp="$(mktemp)"
    {
        printf "debug: false\n"
        printf "language: %s\n" "$(yaml_quote "$NZ_LANGUAGE")"
        printf "listen_host: 0.0.0.0\n"
        printf "listen_port: %s\n" "$NZ_HTTP_PORT"
        printf "site_name: %s\n" "$(yaml_quote "$NZ_SITE_TITLE")"
        printf "install_host: %s\n" "$(yaml_quote "$NZ_INSTALL_HOST")"
        printf "tls: %s\n" "$NZ_AGENT_TLS"
        printf "agent_secret_key: %s\n" "$(yaml_quote "$NZ_AGENT_SECRET_KEY")"
        printf "jwt_secret_key: %s\n" "$(yaml_quote "$NZ_JWT_SECRET_KEY")"
        printf "jwt_timeout: 24\n"
        printf "force_auth: false\n"
    } >"$tmp"
    as_root mkdir -p "$NZ_DASHBOARD_PATH/data"
    as_root install -m 0600 "$tmp" "$NZ_DASHBOARD_PATH/data/config.yaml"
    rm -f "$tmp"
}

write_dashboard_env() {
    NZ_ADMIN_USERNAME="${NZ_ADMIN_USERNAME:-admin}"
    if [ -z "${NZ_ADMIN_PASSWORD:-}" ]; then
        NZ_ADMIN_PASSWORD="$(get_env_value "$NZ_DASHBOARD_PATH/.env" NZ_ADMIN_PASSWORD || true)"
    fi
    NZ_ADMIN_PASSWORD="${NZ_ADMIN_PASSWORD:-$(random_secret 18)}"
    tmp="$(mktemp)"
    {
        printf "RUST_LOG=%s\n" "${RUST_LOG:-info}"
        printf "NZ_ADMIN_USERNAME=%s\n" "$NZ_ADMIN_USERNAME"
        printf "NZ_ADMIN_PASSWORD=%s\n" "$NZ_ADMIN_PASSWORD"
    } >"$tmp"
    as_root install -m 0600 "$tmp" "$NZ_DASHBOARD_PATH/.env"
    rm -f "$tmp"
}

write_dashboard_unit() {
    grpc_bind="${NZ_GRPC_BIND:-0.0.0.0:5555}"
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[Unit]
Description=Nezha Dashboard (Rust)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$NZ_DASHBOARD_PATH
EnvironmentFile=-$NZ_DASHBOARD_PATH/.env
ExecStart=$NZ_DASHBOARD_PATH/app --config $NZ_DASHBOARD_PATH/data/config.yaml --data $NZ_DASHBOARD_PATH/data/sqlite.db --geoip-db $NZ_DASHBOARD_PATH/data/geoip.db --bind $grpc_bind
Restart=always
RestartSec=5
LimitNOFILE=65535
ProtectSystem=full
ReadWritePaths=$NZ_DASHBOARD_PATH
PrivateTmp=yes
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    as_root install -m 0644 "$tmp" "$NZ_DASHBOARD_SERVICE"
    rm -f "$tmp"
}

restart_dashboard_service() {
    as_root systemctl daemon-reload
    as_root systemctl enable nezha-dashboard.service
    as_root systemctl restart nezha-dashboard.service
}

install_dashboard() {
    echo "> Install Dashboard"
    with_tmp_dir
    prepare_download_env
    install_dashboard_binary
    write_dashboard_config
    write_dashboard_env
    write_dashboard_unit
    restart_dashboard_service
    success "Dashboard installed."
    info "HTTP:  http://SERVER_IP:${NZ_HTTP_PORT:-8008}/"
    info "Admin: http://SERVER_IP:${NZ_HTTP_PORT:-8008}/dashboard/"
    info "Admin username: ${NZ_ADMIN_USERNAME:-admin}"
    info "Admin password: ${NZ_ADMIN_PASSWORD}"
}

modify_dashboard_config() {
    echo "> Modify Dashboard Configuration"
    init_common
    write_dashboard_config
    write_dashboard_env
    write_dashboard_unit
    restart_dashboard_service
    success "Dashboard configuration updated."
}

restart_and_update_dashboard() {
    echo "> Restart and Update Dashboard"
    with_tmp_dir
    prepare_download_env
    install_dashboard_binary
    write_dashboard_unit
    restart_dashboard_service
    success "Dashboard restarted and updated from release binaries."
}

show_dashboard_log() {
    echo "> Dashboard Log"
    as_root journalctl -xf -u nezha-dashboard.service
}

uninstall_dashboard() {
    echo "> Uninstall Dashboard"
    warn "This removes $NZ_DASHBOARD_PATH and $NZ_DASHBOARD_SERVICE."
    confirm_uninstall "Dashboard" || return
    as_root systemctl stop nezha-dashboard.service >/dev/null 2>&1 || true
    as_root systemctl disable nezha-dashboard.service >/dev/null 2>&1 || true
    as_root rm -f "$NZ_DASHBOARD_SERVICE"
    as_root rm -rf "$NZ_DASHBOARD_PATH"
    as_root systemctl daemon-reload
    success "Dashboard uninstalled."
}

agent_config_defaults() {
    config="$NZ_AGENT_PATH/config.yml"
    NZ_SERVER="${NZ_SERVER:-$(get_yaml_value "$config" server || true)}"
    NZ_CLIENT_SECRET="${NZ_CLIENT_SECRET:-$(get_yaml_value "$config" client_secret || true)}"
    NZ_TLS="${NZ_TLS:-$(get_yaml_value "$config" tls || true)}"
    if [ -z "${NZ_CLIENT_SECRET:-}" ]; then
        NZ_CLIENT_SECRET="$(get_yaml_value "$NZ_DASHBOARD_PATH/data/config.yaml" agent_secret_key || true)"
    fi
}

write_agent_config() {
    agent_config_defaults
    ask NZ_SERVER "Dashboard gRPC server, e.g. example.com:5555" "127.0.0.1:5555"
    ask NZ_CLIENT_SECRET "Agent client secret" ""
    ask_bool NZ_TLS "Connect with TLS" "${NZ_TLS:-false}"
    if [ -z "$NZ_CLIENT_SECRET" ]; then
        err "Agent client secret cannot be empty."
        exit 1
    fi
    tmp="$(mktemp)"
    {
        printf "server: %s\n" "$(yaml_quote "$NZ_SERVER")"
        printf "client_secret: %s\n" "$(yaml_quote "$NZ_CLIENT_SECRET")"
        printf "tls: %s\n" "$NZ_TLS"
        printf "report_delay: 3\n"
        printf "ip_report_period: 1800\n"
        printf "disable_auto_update: false\n"
        printf "disable_force_update: false\n"
        printf "disable_command_execute: false\n"
        printf "disable_nat: false\n"
        printf "disable_send_query: false\n"
    } >"$tmp"
    as_root mkdir -p "$NZ_AGENT_PATH"
    as_root install -m 0600 "$tmp" "$NZ_AGENT_PATH/config.yml"
    rm -f "$tmp"
}

install_agent() {
    echo "> Install Agent"
    with_tmp_dir
    prepare_download_env
    install_agent_binary
    write_agent_config
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service uninstall >/dev/null 2>&1 || true
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service install
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service start || \
        as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service restart
    success "Agent installed."
}

modify_agent_config() {
    echo "> Modify Agent Configuration"
    init_common
    if [ ! -x "$NZ_AGENT_PATH/nezha-agent" ]; then
        with_tmp_dir
        install_deps
        install_agent_binary
    fi
    write_agent_config
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service restart
    success "Agent configuration updated."
}

restart_agent_update() {
    echo "> Restart and Update Agent"
    with_tmp_dir
    prepare_download_env
    install_agent_binary
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service restart
    success "Agent restarted and updated from release binaries."
}

restart_agent() {
    echo "> Restart Agent"
    as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service restart
}

show_agent_log() {
    echo "> Agent Log"
    as_root journalctl -xf -u nezha-agent.service
}

uninstall_agent() {
    echo "> Uninstall Agent"
    if [ -x "$NZ_AGENT_PATH/nezha-agent" ]; then
        as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service uninstall >/dev/null 2>&1 || true
    else
        as_root systemctl stop nezha-agent.service >/dev/null 2>&1 || true
        as_root systemctl disable nezha-agent.service >/dev/null 2>&1 || true
        as_root rm -f /etc/systemd/system/nezha-agent.service
        as_root systemctl daemon-reload
    fi
    as_root rm -rf "$NZ_AGENT_PATH"
    success "Agent uninstalled."
}

update_script() {
    echo "> Update Script"
    tmp="$(mktemp)"
    download_file "$NZ_SCRIPT_URL" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" ./nezha-rs.sh
    success "Script updated: ./nezha-rs.sh"
}

before_show_menu() {
    echo
    info "Press Enter to return to the main menu"
    read -r _
    show_menu
}

show_usage() {
    cat <<EOF
Nezha Rust Debian installer

Usage:
  $0                         Show menu
  $0 install                 Install Dashboard
  $0 modify_config           Modify Dashboard configuration
  $0 restart_and_update      Download release and restart Dashboard
  $0 show_log                View Dashboard log
  $0 uninstall               Uninstall Dashboard
  $0 uninstall_dashboard     Uninstall Dashboard
  $0 install_agent           Install Agent
  $0 modify_agent_config     Modify Agent configuration
  $0 restart_agent_update    Download release and restart Agent
  $0 restart_agent           Restart Agent
  $0 show_agent_log          View Agent log
  $0 uninstall_agent         Uninstall Agent
  $0 update_script           Download latest installer script

Environment overrides:
  NZ_VERSION=latest or v0.1.0
  NZ_RELEASE_REPO=nezha-rs/nezha-rs
  NZ_SITE_TITLE=Nezha
  NZ_HTTP_PORT=8008
  NZ_GRPC_BIND=0.0.0.0:5555
  NZ_INSTALL_HOST=https://nezha.example.com
  NZ_AGENT_TLS=false
  NZ_AGENT_SECRET_KEY=secret
  NZ_ADMIN_USERNAME=admin
  NZ_ADMIN_PASSWORD=password
  NZ_SERVER=example.com:5555
  NZ_CLIENT_SECRET=secret
  NZ_TLS=false
  NZ_YES=1
EOF
}

show_menu() {
    println "${green}Nezha Rust Debian Management Script${plain}"
    echo "--- https://github.com/${NZ_RELEASE_REPO}/releases ---"
    println "${green}1.${plain}  Install Dashboard"
    println "${green}2.${plain}  Modify Dashboard Configuration"
    println "${green}3.${plain}  Restart and Update Dashboard"
    println "${green}4.${plain}  View Dashboard Log"
    println "${green}5.${plain}  Uninstall Dashboard"
    echo "--------------------------------------------------------"
    println "${green}6.${plain}  Install Agent"
    println "${green}7.${plain}  Modify Agent Configuration"
    println "${green}8.${plain}  Restart and Update Agent"
    println "${green}9.${plain}  Restart Agent"
    println "${green}10.${plain} View Agent Log"
    println "${green}11.${plain} Uninstall Agent"
    echo "--------------------------------------------------------"
    println "${green}12.${plain} Update Script"
    println "${green}0.${plain}  Exit"
    echo
    printf "Please enter [0-12]: "
    read -r num
    case "$num" in
        0) exit 0 ;;
        1) install_dashboard; before_show_menu ;;
        2) modify_dashboard_config; before_show_menu ;;
        3) restart_and_update_dashboard; before_show_menu ;;
        4) show_dashboard_log ;;
        5) uninstall_dashboard; before_show_menu ;;
        6) install_agent; before_show_menu ;;
        7) modify_agent_config; before_show_menu ;;
        8) restart_agent_update; before_show_menu ;;
        9) restart_agent; before_show_menu ;;
        10) show_agent_log ;;
        11) uninstall_agent; before_show_menu ;;
        12) update_script; before_show_menu ;;
        *) err "Please enter a number from 0 to 12."; before_show_menu ;;
    esac
}

case "${1:-}" in
    "") show_menu ;;
    install) install_dashboard ;;
    modify_config) modify_dashboard_config ;;
    restart_and_update) restart_and_update_dashboard ;;
    show_log) show_dashboard_log ;;
    uninstall) uninstall_dashboard ;;
    uninstall_dashboard) uninstall_dashboard ;;
    install_agent) install_agent ;;
    modify_agent_config) modify_agent_config ;;
    restart_agent_update) restart_agent_update ;;
    restart_agent) restart_agent ;;
    show_agent_log) show_agent_log ;;
    uninstall_agent) uninstall_agent ;;
    update_script) update_script ;;
    -h|--help|help) show_usage ;;
    *) show_usage; exit 1 ;;
esac
