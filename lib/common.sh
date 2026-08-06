# shellcheck shell=bash
# Shared helpers for kali-rdp-kit. Sourced, never executed.
# shellcheck disable=SC2034  # these are consumed by the scripts that source us

KRK_VERSION="0.3.0"
KRK_XRDP_DIR="${KRK_XRDP_DIR:-/etc/xrdp}"
KRK_STATE_DIR="${KRK_STATE_DIR:-/var/lib/kali-rdp-kit}"
KRK_BACKUP_DIR="${KRK_BACKUP_DIR:-$KRK_STATE_DIR/backups}"

# --- output -----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
    C_YEL=$'\033[33m';  C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
    C_RESET=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_DIM=; C_BOLD=
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
ok()    { printf '%s  ok%s   %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s  warn%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
err()   { printf '%s  FAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }
step()  { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Prefix every mutating action so --dry-run is honoured uniformly.
run() {
    if [ "${KRK_DRY_RUN:-0}" = 1 ]; then
        printf '%s  would run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root (try: sudo $0 $*)"
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- file editing -----------------------------------------------------------

# Snapshot a file once per run, into a timestamped backup dir.
backup_file() {
    local f=$1 dest
    [ -f "$f" ] || return 0
    dest="$KRK_BACKUP_DIR/${KRK_RUN_ID}"
    run mkdir -p "$dest"
    if [ "${KRK_DRY_RUN:-0}" != 1 ] && [ ! -f "$dest/$(basename "$f")" ]; then
        cp -a "$f" "$dest/" || die "could not back up $f"
    fi
}

# ini_set FILE SECTION KEY VALUE
#
# Idempotently set KEY=VALUE inside [SECTION]. Rewrites an existing key in
# place (including a commented-out one), appends to the section if absent, and
# creates the section at EOF if it does not exist. Returns 1 when nothing
# changed, so callers can report "already correct" honestly.
ini_set() {
    local file=$1 section=$2 key=$3 value=$4 tmp
    [ -f "$file" ] || die "no such file: $file"

    if [ "$(ini_get "$file" "$section" "$key")" = "$value" ]; then
        return 1
    fi

    tmp=$(mktemp) || die "mktemp failed"
    awk -v section="$section" -v key="$key" -v value="$value" '
        function flush_pending() {
            if (in_section && !written) { print key "=" value; written = 1 }
        }
        /^[[:space:]]*\[/ {
            flush_pending()
            cur = $0
            gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", cur)
            in_section = (cur == section)
            if (in_section) seen_section = 1
            print; next
        }
        {
            if (in_section && $0 ~ "^[[:space:]]*[#;]?[[:space:]]*" key "[[:space:]]*=") {
                if (!written) { print key "=" value; written = 1 }
                next
            }
            print
        }
        END {
            flush_pending()
            if (!seen_section) { print ""; print "[" section "]"; print key "=" value }
        }
    ' "$file" >"$tmp" || { rm -f "$tmp"; die "failed rewriting $file"; }

    if [ "${KRK_DRY_RUN:-0}" = 1 ]; then
        printf '%s  would set%s %s [%s] %s=%s\n' \
            "$C_DIM" "$C_RESET" "$(basename "$file")" "$section" "$key" "$value"
        rm -f "$tmp"
        return 0
    fi

    backup_file "$file"
    cat "$tmp" >"$file" || { rm -f "$tmp"; die "failed writing $file"; }
    rm -f "$tmp"
    return 0
}

# ini_get FILE SECTION KEY -> prints value, empty if unset/commented.
ini_get() {
    local file=$1 section=$2 key=$3
    [ -f "$file" ] || return 0
    awk -v section="$section" -v key="$key" '
        /^[[:space:]]*\[/ {
            cur = $0
            gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", cur)
            in_section = (cur == section); next
        }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            sub(/[[:space:]]+$/, "")
            print; exit
        }
    ' "$file"
}

# --- xrdp session introspection --------------------------------------------

# Print "PID DISPLAY" for every running Xvnc session display.
krk_xvnc_sessions() {
    ps -eo pid=,args= 2>/dev/null | awk '
        /[X]vnc[[:space:]]+:[0-9]+/ {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^:[0-9]+$/) { print $1, substr($i, 2); break }
        }'
}

# krk_display_connected DISPLAY -> 0 if an RDP client is attached.
#
# xrdp proxies the client into Xvnc's loopback VNC port (5900+display), so an
# ESTABLISHED connection there means somebody is actually looking at it. When
# the client disconnects the socket closes but Xvnc lingers -- that is exactly
# the orphan we want to reap, and why uptime is the wrong signal.
krk_display_connected() {
    local port=$(( 5900 + $1 ))
    if have ss; then
        ss -tnH state established "( sport = :$port or dport = :$port )" 2>/dev/null \
            | grep -q . && return 0
        return 1
    fi
    netstat -tn 2>/dev/null | awk -v p=":$port" '$6=="ESTABLISHED" && ($4 ~ p"$" || $5 ~ p"$")' \
        | grep -q .
}

# Read a variable out of a process environment (root, or own processes only).
krk_proc_env() {
    local pid=$1 var=$2
    [ -r "/proc/$pid/environ" ] || return 1
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null \
        | awk -F= -v v="$var" '$1==v {sub("^" v "=", ""); print; exit}'
}

# The Xorg backend is usable only when the xorgxrdp driver is installed. The
# presence of the Xorg binary says nothing -- Kali ships Xorg but not
# xorgxrdp, which is precisely the trap this kit exists to remove.
krk_xorgxrdp_usable() {
    dpkg-query -W -f='${Status}' xorgxrdp 2>/dev/null | grep -q "install ok installed"
}

# Node must be system-wide, not per-user. A node installed via nvm lives under
# one user's home and is invisible to every account created afterwards -- which
# is exactly how a freshly provisioned user ends up with a working desktop and
# no runtime at all.
#
# Note this is NOT a Claude Code prerequisite: its native install is a
# self-contained binary. Node is here for ordinary development work, so failing
# to install it must never block anything else.
KRK_NODE_MIN_MAJOR="${KRK_NODE_MIN_MAJOR:-20}"

krk_node_major() {
    local v
    v=$(node --version 2>/dev/null) || return 1
    v=${v#v}
    printf '%s' "${v%%.*}"
}

krk_ensure_node() {
    local major path
    major=$(krk_node_major) || major=""
    path=$(command -v node 2>/dev/null || true)

    if [ -n "$major" ] && [ "$major" -ge "$KRK_NODE_MIN_MAJOR" ] 2>/dev/null; then
        case $path in
            /usr/bin/*|/usr/local/bin/*)
                ok "node $major available system-wide ($path)"
                return 0 ;;
            *)
                # Satisfies the version check for whoever is running this, and
                # nobody else. Install the system copy anyway.
                warn "node $major found at $path -- per-user only, installing system-wide too" ;;
        esac
    fi

    info "installing nodejs and npm system-wide"
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    if ! run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs npm; then
        warn "could not install nodejs; continuing (nothing else here depends on it)"
        return 1
    fi

    if [ "${KRK_DRY_RUN:-0}" != 1 ]; then
        major=$(krk_node_major) || major=""
        if [ -z "$major" ] || ! [ "$major" -ge "$KRK_NODE_MIN_MAJOR" ] 2>/dev/null; then
            # Distro archives lag: Ubuntu 24.04 ships node 18, 22.04 ships 12.
            # Usable, but not current -- say so rather than silently shipping it.
            warn "archive node is ${major:-unknown}, older than the recommended $KRK_NODE_MIN_MAJOR"
            warn "for a current release see https://deb.nodesource.com (adds a third-party repo)"
        fi
    fi
    return 0
}

krk_init_state() {
    KRK_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    export KRK_RUN_ID
    if [ "$(id -u)" -eq 0 ]; then
        run mkdir -p "$KRK_STATE_DIR"
    fi
}
