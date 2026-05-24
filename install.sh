#!/bin/sh
# Compatibility shim for the legacy combined installer.
#
# install.sh used to ship Dashboard + Agent in one script. They are now two
# independent scripts: install-dashboard.sh and install-agent.sh. This shim
# preserves the old subcommands by dispatching to the appropriate new script
# so existing one-liners (`curl ... | sh -s -- install_agent`) keep working.

set -eu

NZ_SCRIPT_BASE_URL="${NZ_SCRIPT_BASE_URL:-https://raw.githubusercontent.com/nezha-rs/scripts/main}"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() { printf "${red}%s${plain}\n" "$*" >&2; }
info() { printf "${yellow}%s${plain}\n" "$*"; }
println() { printf "%s\n" "$*"; }

# Locate a target script: prefer a sibling file, fall back to fetching the
# script from NZ_SCRIPT_BASE_URL.
_nz_resolve_script() {
    name="$1"
    script_dir=""
    case "${0:-}" in
        /*) script_dir="$(dirname "$0")" ;;
        */*) script_dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" ;;
        *) script_dir="" ;;
    esac
    if [ -n "$script_dir" ] && [ -r "$script_dir/$name" ]; then
        printf "local:%s/%s" "$script_dir" "$name"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required to fetch $name from $NZ_SCRIPT_BASE_URL"
        return 1
    fi
    tmp="$(mktemp)"
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
            "${NZ_SCRIPT_BASE_URL}/${name}" -o "$tmp"; then
        rm -f "$tmp"
        err "failed to fetch ${name} from ${NZ_SCRIPT_BASE_URL}"
        return 1
    fi
    chmod +x "$tmp"
    printf "remote:%s" "$tmp"
}

_nz_run() {
    name="$1"
    shift
    resolved="$(_nz_resolve_script "$name")" || exit 1
    case "$resolved" in
        local:*)
            path="${resolved#local:}"
            sh "$path" "$@"
            rc=$?
            ;;
        remote:*)
            path="${resolved#remote:}"
            sh "$path" "$@"
            rc=$?
            rm -f "$path"
            ;;
        *)
            err "unexpected resolver output: $resolved"
            exit 1
            ;;
    esac
    return "$rc"
}

show_menu() {
    println "${green}Nezha Rust Management Script${plain}"
    echo "install.sh has been split into two independent installers."
    println "${green}1.${plain}  Dashboard management  (install-dashboard.sh)"
    println "${green}2.${plain}  Agent management      (install-agent.sh)"
    println "${green}0.${plain}  Exit"
    echo
    printf "Please enter [0-2]: "
    read -r choice
    case "$choice" in
        0) exit 0 ;;
        1) _nz_run install-dashboard.sh ;;
        2) _nz_run install-agent.sh ;;
        *) err "Please enter a number from 0 to 2."; show_menu ;;
    esac
}

show_usage() {
    cat <<EOF
Nezha Rust installer (compatibility shim)

install.sh now dispatches to two independent scripts:
  - install-dashboard.sh : Dashboard install / config / uninstall / update
  - install-agent.sh     : Agent install / config / uninstall / update

Examples:
  $0                                 Show selection menu
  $0 install                         Install Dashboard
  $0 install_agent                   Install Agent
  $0 uninstall_dashboard             Uninstall Dashboard
  $0 uninstall_agent                 Uninstall Agent

You can also call the new scripts directly:
  ./install-dashboard.sh install
  ./install-agent.sh install
EOF
}

case "${1:-}" in
    "") show_menu ;;

    # Dashboard subcommands → install-dashboard.sh
    install|modify_config|restart_and_update|show_log|uninstall|uninstall_dashboard|update_script)
        cmd="$1"
        shift
        case "$cmd" in
            uninstall_dashboard) cmd="uninstall" ;;
        esac
        _nz_run install-dashboard.sh "$cmd" "$@"
        ;;

    # Agent subcommands → install-agent.sh
    install_agent|modify_agent_config|restart_agent_update|restart_agent|show_agent_log|uninstall_agent)
        cmd="$1"
        shift
        case "$cmd" in
            install_agent) cmd="install" ;;
            modify_agent_config) cmd="modify_config" ;;
            restart_agent_update) cmd="restart_and_update" ;;
            restart_agent) cmd="restart" ;;
            show_agent_log) cmd="show_log" ;;
            uninstall_agent) cmd="uninstall" ;;
        esac
        _nz_run install-agent.sh "$cmd" "$@"
        ;;

    -h|--help|help) show_usage ;;
    *) show_usage; exit 1 ;;
esac
