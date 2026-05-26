#!/bin/sh
# Nezha Rust Dashboard installer (Debian 12+).
# Usage:
#   ./install-dashboard.sh                  Show menu
#   ./install-dashboard.sh install          Install Dashboard
#   ./install-dashboard.sh modify_config    Modify Dashboard config
#   ./install-dashboard.sh restart_and_update
#   ./install-dashboard.sh show_log
#   ./install-dashboard.sh uninstall
#   ./install-dashboard.sh update_script

set -eu
( set -o pipefail 2>/dev/null ) && set -o pipefail || true

# Locate or fetch the shared lib.
_nz_load_common() {
    if [ -n "${NZ_COMMON_LIB:-}" ] && [ -r "$NZ_COMMON_LIB" ]; then
        . "$NZ_COMMON_LIB"
        return
    fi
    script_dir=""
    case "${0:-}" in
        /*) script_dir="$(dirname "$0")" ;;
        */*) script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" ;;
        *) script_dir="" ;;
    esac
    if [ -n "$script_dir" ] && [ -r "$script_dir/lib/common.sh" ]; then
        . "$script_dir/lib/common.sh"
        return
    fi
    # Piped via curl | sh: download the lib next to whatever cache dir we can use.
    NZ_SCRIPT_BASE_URL="${NZ_SCRIPT_BASE_URL:-https://raw.githubusercontent.com/nezha-rs/scripts/main}"
    tmplib="$(mktemp)"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
            "${NZ_SCRIPT_BASE_URL}/lib/common.sh" -o "$tmplib"; then
        printf "failed to fetch lib/common.sh from %s\n" "$NZ_SCRIPT_BASE_URL" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    . "$tmplib"
    rm -f "$tmplib"
}
_nz_load_common

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

install_dashboard_binary() {
    download_dashboard_binary
    as_root mkdir -p "$NZ_DASHBOARD_PATH"
    as_root install -m 0755 "$NZ_DOWNLOADED_DASHBOARD" "$NZ_DASHBOARD_PATH/app"
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

dashboard_supports_admin_password_reset() {
    as_root "$NZ_DASHBOARD_PATH/app" --help 2>/dev/null | grep -q "reset-admin-password"
}

reset_dashboard_admin_password() {
    NZ_ADMIN_PASSWORD_SYNCED=0
    if ! dashboard_supports_admin_password_reset; then
        warn "Dashboard binary does not support admin password sync."
        warn "If this is not a fresh install, the printed password may not match the existing database password."
        return
    fi

    info "> Sync Dashboard admin password"
    # Pass via env file rather than command line to keep the password out of
    # /proc/*/cmdline and shell history.
    env_file="$(mktemp)"
    chmod 600 "$env_file"
    {
        printf "NZ_ADMIN_USERNAME=%s\n" "$NZ_ADMIN_USERNAME"
        printf "NZ_ADMIN_PASSWORD=%s\n" "$NZ_ADMIN_PASSWORD"
    } >"$env_file"
    if ! as_root env -i "PATH=$PATH" sh -c '
        set -eu
        # shellcheck disable=SC1090
        . "$1"
        export NZ_ADMIN_USERNAME NZ_ADMIN_PASSWORD
        "$2" --data "$3" reset-admin-password >/dev/null
    ' _ "$env_file" "$NZ_DASHBOARD_PATH/app" "$NZ_DASHBOARD_PATH/data/sqlite.db"; then
        rm -f "$env_file"
        err "failed to sync dashboard admin password"
        exit 1
    fi
    rm -f "$env_file"
    NZ_ADMIN_PASSWORD_SYNCED=1
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
ProtectSystem=strict
ReadWritePaths=$NZ_DASHBOARD_PATH
ProtectHome=true
PrivateTmp=yes
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectProc=invisible
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

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
    reset_dashboard_admin_password
    write_dashboard_unit
    restart_dashboard_service
    success "Dashboard installed."
    info "Dashboard HTTP: http://SERVER_IP:${NZ_HTTP_PORT:-8008}/"
    info "Dashboard Admin: http://SERVER_IP:${NZ_HTTP_PORT:-8008}/dashboard/"
    info "Agent gRPC: $(display_bind "${NZ_GRPC_BIND:-0.0.0.0:5555}")"
    info "Admin username: ${NZ_ADMIN_USERNAME:-admin}"
    if [ "${NZ_ADMIN_PASSWORD_SYNCED:-0}" = "1" ]; then
        info "Admin password: stored in $NZ_DASHBOARD_PATH/.env (NZ_ADMIN_PASSWORD)."
        info "Run as root:  sudo grep ^NZ_ADMIN_PASSWORD= $NZ_DASHBOARD_PATH/.env"
    else
        warn "Admin password was not synced to the dashboard database."
        warn "On a fresh install, the value in $NZ_DASHBOARD_PATH/.env (NZ_ADMIN_PASSWORD) is what will work."
    fi
}

modify_dashboard_config() {
    echo "> Modify Dashboard Configuration"
    init_common
    write_dashboard_config
    write_dashboard_env
    reset_dashboard_admin_password
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

update_script() {
    echo "> Update Script"
    tmp="$(mktemp)"
    download_file "${NZ_SCRIPT_BASE_URL}/install-dashboard.sh" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" ./nezha-dashboard.sh
    success "Script updated: ./nezha-dashboard.sh"
}

before_show_menu() {
    echo
    info "Press Enter to return to the main menu"
    read -r _
    show_menu
}

show_usage() {
    cat <<EOF
Nezha Rust Dashboard installer (Debian 12+)

Usage:
  $0                         Show menu
  $0 install                 Install Dashboard
  $0 modify_config           Modify Dashboard configuration
  $0 restart_and_update      Download release and restart Dashboard
  $0 show_log                View Dashboard log
  $0 uninstall               Uninstall Dashboard
  $0 update_script           Download latest installer script

Environment overrides:
  NZ_VERSION=latest or v0.1.0
  NZ_RELEASE_REPO=nezha-rs/nezha-rs
  NZ_SITE_TITLE=Nezha
  NZ_HTTP_PORT=8008          Dashboard HTTP panel port
  NZ_GRPC_BIND=0.0.0.0:5555  Agent gRPC access port
  NZ_INSTALL_HOST=https://nezha.example.com
  NZ_AGENT_TLS=false
  NZ_AGENT_SECRET_KEY=secret
  NZ_ADMIN_USERNAME=admin
  NZ_ADMIN_PASSWORD=password
  NZ_YES=1
EOF
}

show_menu() {
    println "${green}Nezha Rust Dashboard Management Script${plain}"
    echo "--- https://github.com/${NZ_RELEASE_REPO}/releases ---"
    println "${green}1.${plain}  Install Dashboard"
    println "${green}2.${plain}  Modify Dashboard Configuration"
    println "${green}3.${plain}  Restart and Update Dashboard"
    println "${green}4.${plain}  View Dashboard Log"
    println "${green}5.${plain}  Uninstall Dashboard"
    echo "--------------------------------------------------------"
    println "${green}6.${plain}  Update Script"
    println "${green}0.${plain}  Exit"
    echo
    printf "Please enter [0-6]: "
    read -r num
    case "$num" in
        0) exit 0 ;;
        1) install_dashboard; before_show_menu ;;
        2) modify_dashboard_config; before_show_menu ;;
        3) restart_and_update_dashboard; before_show_menu ;;
        4) show_dashboard_log ;;
        5) uninstall_dashboard; before_show_menu ;;
        6) update_script; before_show_menu ;;
        *) err "Please enter a number from 0 to 6."; before_show_menu ;;
    esac
}

case "${1:-}" in
    "") show_menu ;;
    install) install_dashboard ;;
    modify_config) modify_dashboard_config ;;
    restart_and_update) restart_and_update_dashboard ;;
    show_log) show_dashboard_log ;;
    uninstall|uninstall_dashboard) uninstall_dashboard ;;
    update_script) update_script ;;
    -h|--help|help) show_usage ;;
    *) show_usage; exit 1 ;;
esac
