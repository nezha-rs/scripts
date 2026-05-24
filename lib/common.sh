# Shared helpers for the Nezha Rust installer scripts.
# Sourced by install-dashboard.sh and install-agent.sh.
# Do not execute directly.

set -eu
( set -o pipefail 2>/dev/null ) && set -o pipefail || true

NZ_BASE_PATH="${NZ_BASE_PATH:-/opt/nezha}"
NZ_DASHBOARD_PATH="${NZ_DASHBOARD_PATH:-${NZ_BASE_PATH}/dashboard}"
NZ_AGENT_PATH="${NZ_AGENT_PATH:-${NZ_BASE_PATH}/agent}"
NZ_DASHBOARD_SERVICE="/etc/systemd/system/nezha-dashboard.service"
NZ_RELEASE_REPO="${NZ_RELEASE_REPO:-nezha-rs/nezha-rs}"
NZ_SCRIPT_BASE_URL="${NZ_SCRIPT_BASE_URL:-https://raw.githubusercontent.com/nezha-rs/scripts/main}"
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
    new_tmp="$(mktemp -d)"
    if [ -n "${NZ_TMP_DIRS:-}" ]; then
        NZ_TMP_DIRS="$NZ_TMP_DIRS
$new_tmp"
    else
        NZ_TMP_DIRS="$new_tmp"
    fi
    NZ_TMP_DIR="$new_tmp"
    trap '_nz_cleanup_tmp_dirs' EXIT INT TERM
}

_nz_cleanup_tmp_dirs() {
    if [ -z "${NZ_TMP_DIRS:-}" ]; then
        return
    fi
    OLDIFS="${IFS-}"
    IFS='
'
    for d in $NZ_TMP_DIRS; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
    done
    IFS="$OLDIFS"
    NZ_TMP_DIRS=""
}

random_secret() {
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"
}

yaml_quote() {
    printf "%s" "$1" | sed "s/'/''/g; s/^/'/; s/$/'/"
}

display_bind() {
    bind="$1"
    case "$bind" in
        0.0.0.0:*)
            printf "SERVER_IP:%s" "${bind##*:}"
            ;;
        "[::]":*)
            printf "SERVER_IP:%s" "${bind##*:}"
            ;;
        *)
            printf "%s" "$bind"
            ;;
    esac
}

get_yaml_value() {
    file="$1"
    key="$2"
    _nz_yaml_extract() {
        awk -v key="$1" '
        {
            line = $0
            sub(/\r$/, "", line)
            if (line ~ /^[ \t]*#/) next
            if (line ~ /^[ \t]*$/) next
            i = index(line, ":")
            if (i == 0) next
            k = substr(line, 1, i - 1)
            v = substr(line, i + 1)
            sub(/^[ \t]+/, "", k)
            sub(/[ \t]+$/, "", k)
            if (k != key) next
            sub(/^[ \t]+/, "", v)
            if (substr(v, 1, 1) == "\"") {
                rest = substr(v, 2)
                out = ""
                esc = 0
                for (j = 1; j <= length(rest); j++) {
                    c = substr(rest, j, 1)
                    if (esc) { out = out c; esc = 0; continue }
                    if (c == "\\") { esc = 1; continue }
                    if (c == "\"") break
                    out = out c
                }
                v = out
            } else if (substr(v, 1, 1) == "'\''") {
                rest = substr(v, 2)
                out = ""
                for (j = 1; j <= length(rest); j++) {
                    c = substr(rest, j, 1)
                    if (c == "'\''") {
                        if (substr(rest, j + 1, 1) == "'\''") { out = out "'\''"; j++; continue }
                        break
                    }
                    out = out c
                }
                v = out
            } else {
                sub(/[ \t]+$/, "", v)
                sub(/[ \t]+#.*$/, "", v)
                sub(/[ \t]+$/, "", v)
            }
            print v
            exit
        }
        ' "$2"
    }
    if [ -r "$file" ]; then
        _nz_yaml_extract "$key" "$file"
    elif command -v sudo >/dev/null 2>&1; then
        sudo cat "$file" 2>/dev/null | _nz_yaml_extract "$key" /dev/stdin
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

# Resolve a readable interactive input source. Prefer the controlling TTY so
# that piped invocations (`curl ... | sh`) can still prompt the user. Sets the
# global NZ_TTY_IN to a path readable by `read`, or empty if no interactive
# input is available.
_nz_resolve_tty() {
    NZ_TTY_IN=""
    if [ -t 0 ] && [ -r /dev/stdin ]; then
        NZ_TTY_IN="/dev/stdin"
        return 0
    fi
    if [ -r /dev/tty ] 2>/dev/null; then
        NZ_TTY_IN="/dev/tty"
        return 0
    fi
    return 1
}

_nz_prompt() {
    if [ -w /dev/tty ] 2>/dev/null; then
        printf "%s" "$1" >/dev/tty
    else
        printf "%s" "$1" >&2
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
    answer=""
    if _nz_resolve_tty; then
        if [ -n "$default" ]; then
            _nz_prompt "$prompt [$default]: "
        else
            _nz_prompt "$prompt: "
        fi
        read -r answer <"$NZ_TTY_IN" || answer=""
    fi
    [ -n "$answer" ] || answer="$default"
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
    answer=""
    if _nz_resolve_tty; then
        if [ "$default" = "true" ]; then
            _nz_prompt "$prompt [Y/n]: "
        else
            _nz_prompt "$prompt [y/N]: "
        fi
        read -r answer <"$NZ_TTY_IN" || answer=""
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
    if _nz_resolve_tty; then
        _nz_prompt "Proceed to uninstall ${target}? [y/N]: "
        answer=""
        read -r answer <"$NZ_TTY_IN" || answer=""
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            *) return 1 ;;
        esac
    fi
    return 1
}
