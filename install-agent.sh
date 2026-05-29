#!/bin/sh
# Nezha Rust Agent installer (Debian 12+).
# Usage:
#   ./install-agent.sh                 Show menu
#   ./install-agent.sh install         Install Agent
#   ./install-agent.sh modify_config   Modify Agent config
#   ./install-agent.sh restart_and_update
#   ./install-agent.sh restart
#   ./install-agent.sh show_log
#   ./install-agent.sh uninstall
#   ./install-agent.sh update_script

set -eu
( set -o pipefail 2>/dev/null ) && set -o pipefail || true

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

agent_asset_name() {
    printf "nezha-agent_linux_%s.zip" "$os_arch"
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

install_agent_binary() {
    download_agent_binary
    as_root mkdir -p "$NZ_AGENT_PATH"
    as_root install -m 0755 "$NZ_DOWNLOADED_AGENT" "$NZ_AGENT_PATH/nezha-agent"
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
    warn "This removes $NZ_AGENT_PATH and the nezha-agent service."
    confirm_uninstall "Agent" || return
    if [ -x "$NZ_AGENT_PATH/nezha-agent" ]; then
        as_root "$NZ_AGENT_PATH/nezha-agent" --config "$NZ_AGENT_PATH/config.yml" service uninstall >/dev/null 2>&1 || true
    fi
    as_root systemctl stop nezha-agent.service >/dev/null 2>&1 || true
    as_root systemctl disable nezha-agent.service >/dev/null 2>&1 || true
    as_root rm -f /etc/systemd/system/nezha-agent.service
    as_root systemctl daemon-reload
    as_root rm -rf "$NZ_AGENT_PATH"
    success "Agent uninstalled."
}

update_script() {
    echo "> Update Script"
    tmp="$(mktemp)"
    download_file "${NZ_SCRIPT_BASE_URL}/install-agent.sh" "$tmp"
    chmod +x "$tmp"
    mv -f "$tmp" ./nezha-agent.sh
    success "Script updated: ./nezha-agent.sh"
}

before_show_menu() {
    echo
    info "Press Enter to return to the main menu"
    read -r _
    show_menu
}

show_usage() {
    cat <<EOF
Nezha Rust Agent installer (Debian 12+)

Usage:
  $0                         Show menu
  $0 install                 Install Agent
  $0 modify_config           Modify Agent configuration
  $0 restart_and_update      Download release and restart Agent
  $0 restart                 Restart Agent
  $0 show_log                View Agent log
  $0 uninstall               Uninstall Agent
  $0 update_script           Download latest installer script

Environment overrides:
  NZ_VERSION=latest or v0.1.0
  NZ_RELEASE_REPO=nezha-rs/nezha-rs
  NZ_SERVER=nezha.example.com:5555
  NZ_CLIENT_SECRET=secret
  NZ_TLS=false
  NZ_YES=1
EOF
}

show_menu() {
    println "${green}Nezha Rust Agent Management Script${plain}"
    echo "--- https://github.com/${NZ_RELEASE_REPO}/releases ---"
    println "${green}1.${plain}  Install Agent"
    println "${green}2.${plain}  Modify Agent Configuration"
    println "${green}3.${plain}  Restart and Update Agent"
    println "${green}4.${plain}  Restart Agent"
    println "${green}5.${plain}  View Agent Log"
    println "${green}6.${plain}  Uninstall Agent"
    echo "--------------------------------------------------------"
    println "${green}7.${plain}  Update Script"
    println "${green}0.${plain}  Exit"
    echo
    printf "Please enter [0-7]: "
    read -r num
    case "$num" in
        0) exit 0 ;;
        1) install_agent; before_show_menu ;;
        2) modify_agent_config; before_show_menu ;;
        3) restart_agent_update; before_show_menu ;;
        4) restart_agent; before_show_menu ;;
        5) show_agent_log ;;
        6) uninstall_agent; before_show_menu ;;
        7) update_script; before_show_menu ;;
        *) err "Please enter a number from 0 to 7."; before_show_menu ;;
    esac
}

case "${1:-}" in
    "") show_menu ;;
    install|install_agent) install_agent ;;
    modify_config|modify_agent_config) modify_agent_config ;;
    restart_and_update|restart_agent_update) restart_agent_update ;;
    restart|restart_agent) restart_agent ;;
    show_log|show_agent_log) show_agent_log ;;
    uninstall|uninstall_agent) uninstall_agent ;;
    update_script) update_script ;;
    -h|--help|help) show_usage ;;
    *) show_usage; exit 1 ;;
esac
