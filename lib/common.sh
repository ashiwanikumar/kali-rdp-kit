# shellcheck shell=bash
# Shared helpers for kali-rdp-kit. Sourced, never executed.
# shellcheck disable=SC2034  # these are consumed by the scripts that source us

KRK_VERSION="0.5.0"
KRK_XRDP_DIR="${KRK_XRDP_DIR:-/etc/xrdp}"
KRK_XRDP_LOG="${KRK_XRDP_LOG:-/var/log/xrdp.log}"
KRK_SESMAN_LOG="${KRK_SESMAN_LOG:-/var/log/xrdp-sesman.log}"
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

# A path that exists, even when it is a symlink whose target this process
# cannot reach. /etc/xrdp/key.pem points into /etc/ssl/private, which is 0710
# root:ssl-cert: to anyone outside that group `test -e` follows the link, fails
# to traverse the directory, and reports the key as absent. Announcing "the TLS
# key does not exist" about a perfectly working server is worse than saying
# nothing, so existence and readability are asked as two separate questions --
# see krk_can_read_as for the second.
krk_path_present() { [ -e "$1" ] || [ -L "$1" ]; }

# --- file editing -----------------------------------------------------------

# Snapshot a file once per run, into a timestamped backup dir.
#
# The run id normally comes from krk_init_state. Deriving one here when it is
# missing means a caller that edits a file without initialising state still
# gets a backup, instead of aborting under `set -u` at the moment it is about
# to overwrite something.
backup_file() {
    local f=$1 dest
    [ -f "$f" ] || return 0
    [ -n "${KRK_RUN_ID:-}" ] || KRK_RUN_ID="$(date +%Y%m%d-%H%M%S)"
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
# Kept as the narrow view onto krk_xvnc_inventory (defined below) so that both
# share one notion of what counts as a session -- including its de-duplication.
krk_xvnc_sessions() {
    krk_xvnc_inventory | while IFS=$'\t' read -r pid display _rest; do
        printf '%s %s\n' "$pid" "$display"
    done
}

# krk_display_connected DISPLAY -> 0 if an RDP client is attached.
#
# xrdp proxies the client into Xvnc's loopback VNC port (5900+display), so an
# ESTABLISHED connection there means somebody is actually looking at it. When
# the client disconnects the socket closes but Xvnc lingers -- that is exactly
# the orphan we want to reap, and why uptime is the wrong signal.
krk_display_connected() {
    # 10# forces base ten: bash reads a leading zero as octal, so a display
    # written ":08" would otherwise be an arithmetic error rather than 8.
    local port=$(( 5900 + 10#$1 ))
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

# --- process lineage --------------------------------------------------------
#
# /proc/PID/stat is world-readable, so every one of these works unprivileged --
# unlike krk_proc_env, which needs to own the process or be root.

krk_pid_ppid() {
    local st
    st=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    # comm can contain spaces and parentheses, so index past the last ')'.
    st=${st##*) }
    set -- $st
    printf '%s' "$2"          # state is $1, ppid is $2
}

# krk_pid_start_epoch PID -- when the process began.
# The /proc/PID directory's mtime is the process start time, which avoids
# parsing ps(1) date formats or reconciling clock ticks against /proc/stat.
krk_pid_start_epoch() { stat -c %Y "/proc/$1" 2>/dev/null; }

krk_pid_comm() { cat "/proc/$1/comm" 2>/dev/null; }

# PID of the running session manager, empty when it is not running.
krk_sesman_pid() {
    local p
    p=$(systemctl show xrdp-sesman -p MainPID --value 2>/dev/null)
    case ${p:-0} in ''|0) ;; *) printf '%s' "$p"; return 0 ;; esac
    p=$(pgrep -x xrdp-sesman 2>/dev/null | head -1)
    [ -n "$p" ] && printf '%s' "$p"
}

# krk_session_orphaned PID -> 0 when this Xvnc is no longer tracked by sesman.
#
# sesman keeps its session table in memory only. Restarting or crashing it
# therefore forgets every desktop while the Xvnc processes themselves survive
# (they live in a logind session scope, not sesman's cgroup, so systemd does
# not take them down with the unit). The result is a desktop that is still
# running with the user's work in it, still holding VNC port 5900+display, and
# that no client can ever rejoin -- reconnecting silently builds a *new* empty
# desktop instead.
#
# The test is the *shape* of the parentage, not mere descent from sesman:
#
#     Xvnc  ->  xrdp-sesexec  ->  xrdp-sesman        tracked
#
# Descent alone would be badly wrong, because everything a user launches inside
# their desktop -- their shell, their editor, this script -- is also a
# descendant of sesman, so every hand-started X server would look tracked. A
# session sesman has forgotten has lost that chain: sesexec is gone or has been
# reparented to init.
krk_session_orphaned() {
    local pid=$1 sesman parent
    sesman=$(krk_sesman_pid) || true
    [ -n "$sesman" ] || return 0            # no sesman at all: nothing is tracked
    parent=$(krk_pid_ppid "$pid") || return 0
    [ -n "$parent" ] || return 0
    # Older xrdp forks the session straight out of sesman, with no sesexec.
    [ "$parent" = "$sesman" ] && return 1
    case $(krk_pid_comm "$parent") in
        xrdp-sesexec|xrdp-sesman) ;;
        *) return 0 ;;
    esac
    [ "$(krk_pid_ppid "$parent")" = "$sesman" ] && return 1
    return 0
}

# --- xvnc inventory ---------------------------------------------------------

# Print one TAB-separated record per Xvnc: pid, display, depth, geometry, kind.
#
# "kind" is sesman when xrdp started the server (recognisable by the
# sesman_passwd rfbauth file) and standalone otherwise -- a desktop the user
# started with vncserver(1) by hand is not xrdp's to reason about, and must
# never be counted as an xrdp orphan.
krk_xvnc_inventory() {
    ps -eo pid=,ppid=,args= 2>/dev/null | awk '
        /[X]vnc[[:space:]]+:[0-9]+/ {
            pid = $1; ppid = $2; disp = ""; depth = ""; geom = ""; kind = "standalone"
            for (i = 3; i <= NF; i++) {
                if (disp == "" && $i ~ /^:[0-9]+$/)   disp  = substr($i, 2)
                else if ($i == "-depth")              depth = $(i + 1)
                else if ($i == "-geometry")           geom  = $(i + 1)
                else if ($i ~ /sesman_passwd/)        kind  = "sesman"
            }
            if (disp == "") next
            n++
            p[n] = pid; pp[n] = ppid; d[n] = disp
            rec[n] = pid "\t" disp "\t" (depth == "" ? "?" : depth) "\t" \
                     (geom == "" ? "?" : geom) "\t" kind
        }
        END {
            # An Xvnc that daemonises is briefly visible twice: the launcher and
            # the server it forked. Reporting both would double-count desktops
            # and send a reaper after a pid that is already gone. Drop any entry
            # that is the parent of another Xvnc on the same display.
            for (i = 1; i <= n; i++) {
                drop = 0
                for (j = 1; j <= n; j++)
                    if (i != j && pp[j] == p[i] && d[j] == d[i]) drop = 1
                if (!drop) print rec[i]
            }
        }'
}

# Login name owning a pid, empty when it cannot be determined.
krk_pid_user() { ps -o user= -p "$1" 2>/dev/null | tr -d ' '; }

# --- log scoping ------------------------------------------------------------
#
# Grepping a whole xrdp.log is the reason a fixed problem keeps being reported
# as broken: these files are never truncated, so one bad minute weeks ago is
# still "current" to a naive grep. Every log check must be scoped to the
# lifetime of the process that would be producing the errors.

# krk_service_start_epoch UNIT -> unix time the unit last entered active state.
krk_service_start_epoch() {
    local ts epoch pid
    ts=$(systemctl show "$1" -p ActiveEnterTimestamp --value 2>/dev/null)
    if [ -n "$ts" ]; then
        epoch=$(date -d "$ts" +%s 2>/dev/null) && [ -n "$epoch" ] && {
            printf '%s' "$epoch"; return 0; }
    fi
    # No systemd, or a unit that has never activated: fall back to the main
    # process's own start time.
    pid=$(systemctl show "$1" -p MainPID --value 2>/dev/null)
    case ${pid:-0} in ''|0) return 1 ;; esac
    krk_pid_start_epoch "$pid"
}

# krk_log_since FILE EPOCH -- emit only the lines stamped at or after EPOCH.
#
# Handles both stamp formats xrdp has shipped:
#     [2026-08-06T04:59:53.239+0400]   (0.10+)
#     [20260806-04:59:53]              (older)
# Lines with no stamp of their own (wrapped tracebacks) inherit the previous
# line's verdict. Comparison is on local wall-clock text rather than parsed
# epochs, so it needs no mktime and works under mawk as well as gawk.
#
# Returns 1 when the file cannot be read at all -- callers must distinguish
# "no errors" from "could not look", or an unprivileged run reports a clean
# bill of health it never actually checked.
krk_log_since() {
    local file=$1 epoch=$2 cutoff f first
    [ -r "$file" ] || return 1
    # A second of slack absorbs sub-second rounding between systemd's timestamp
    # and the first line xrdp writes.
    cutoff=$(date -d "@$(( epoch - 1 ))" +%Y%m%d%H%M%S 2>/dev/null) || return 1
    [ -n "$cutoff" ] || return 1

    # If the file carries no recognisable stamps, scoping is impossible; emit
    # everything rather than silently reporting nothing.
    if ! head -n 40 "$file" 2>/dev/null | grep -q '^\['; then
        cat "$file"; return 0
    fi

    # Logrotate can move the start of the window into the previous file. Only
    # go looking when the live file itself begins after the cutoff.
    # Stamps are fixed-width digits, so a numeric test is both correct and
    # free of the string-comparison operators that differ between shells.
    first=$(krk_log_first_stamp "$file")
    if [ -n "$first" ] && [ "$first" -gt "$cutoff" ] 2>/dev/null; then
        for f in "$file.1" "$file.0"; do
            [ -r "$f" ] && krk_log_filter "$f" "$cutoff"
        done
        for f in "$file.1.gz" "$file.0.gz"; do
            [ -r "$f" ] && have zcat && zcat "$f" 2>/dev/null | krk_log_filter - "$cutoff"
        done
    fi
    krk_log_filter "$file" "$cutoff"
}

# Sortable YYYYMMDDHHMMSS of a log line, or empty when it carries no stamp.
krk_log_stamp_awk='
    function stamp_of(line,   s) {
        if (substr(line, 1, 1) != "[") return ""
        s = substr(line, 2, 19)                       # 2026-08-06T04:59:53
        if (substr(s, 5, 1) == "-" && substr(s, 11, 1) == "T") {
            gsub(/[-T:]/, "", s); return s
        }
        s = substr(line, 2, 17)                       # 20260806-04:59:53
        if (substr(s, 9, 1) == "-" && substr(s, 12, 1) == ":") {
            gsub(/[-:]/, "", s); return s
        }
        return ""
    }'

krk_log_filter() {
    awk -v cutoff="$2" "$krk_log_stamp_awk"'
        { s = stamp_of($0); if (s != "") emit = (s >= cutoff); if (emit) print }
    ' "$1"
}

krk_log_first_stamp() {
    awk "$krk_log_stamp_awk"'
        { s = stamp_of($0); if (s != "") { print s; exit } }
        NR > 200 { exit }
    ' "$1" 2>/dev/null
}

# --- TLS --------------------------------------------------------------------

# krk_cert_self_signed CERT -> 0 self-signed, 1 CA-signed, 2 undetermined.
krk_cert_self_signed() {
    local cert=$1 subject issuer
    # The snakeoil pair is self-signed by construction; recognise it even on a
    # host with no openssl binary.
    case $(readlink -f "$cert" 2>/dev/null || printf '%s' "$cert") in
        *ssl-cert-snakeoil*) return 0 ;;
    esac
    have openssl || return 2
    [ -r "$cert" ] || return 2
    subject=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null) || return 2
    issuer=$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null)  || return 2
    [ "${subject#subject=}" = "${issuer#issuer=}" ]
}

# krk_cert_days_left CERT -> whole days until notAfter (negative if expired).
krk_cert_days_left() {
    local cert=$1 end now
    have openssl || return 1
    [ -r "$cert" ] || return 1
    end=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null) || return 1
    end=${end#notAfter=}
    end=$(date -d "$end" +%s 2>/dev/null) || return 1
    now=$(date +%s)
    # Integer division truncates toward zero, so a certificate that expired an
    # hour ago would come back as 0 and be reported as "expires in 0 days"
    # rather than as expired. Round away from zero on the negative side.
    if [ "$end" -le "$now" ]; then
        printf '%s' "-$(( (now - end + 86399) / 86400 ))"
    else
        printf '%s' $(( (end - now) / 86400 ))
    fi
}

# krk_can_read_as USER FILE -> 0 readable, 1 not readable, 2 could not test.
#
# A live read as the actual user is the only honest answer: group membership,
# ACLs and the execute bits on every parent directory all have to line up, and
# checking any one of them in isolation produces confident wrong answers.
# The three answers must stay distinct. "Could not test" reported as "not
# readable" is what makes a tool refuse to apply its own fix, so each candidate
# mechanism is first proved against a control file that is readable by
# definition; only a mechanism that passes the control is trusted to answer.
krk_can_read_as() {
    local user=$1 file=$2
    [ "$(id -u)" -eq 0 ] || return 2
    if have runuser && runuser -u "$user" -- test -r /dev/null 2>/dev/null; then
        runuser -u "$user" -- test -r "$file" 2>/dev/null && return 0
        return 1
    fi
    if have sudo && sudo -n -u "$user" test -r /dev/null 2>/dev/null; then
        sudo -n -u "$user" test -r "$file" 2>/dev/null && return 0
        return 1
    fi
    return 2
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

# --- desktop settings ------------------------------------------------------

# krk_disable_autostart USER HOME APP...
#
# Suppress a desktop autostart entry via the freedesktop override mechanism.
#
# This is deliberately used instead of toggling an application's own settings:
# a program that never starts cannot lock the screen, whatever its config says,
# and it works identically whether or not the user has ever logged in. Editing
# an app's config only helps if the config is read, is not overwritten by a
# running settings daemon, and the app honours it.
krk_disable_autostart() {
    local user=$1 home=$2; shift 2
    local dir="$home/.config/autostart" app f grp
    grp=$(id -gn "$user" 2>/dev/null) || grp=$user

    for app in "$@"; do
        # Only shadow entries that actually exist system-wide; writing an
        # override for an uninstalled app just litters the profile.
        [ -f "/etc/xdg/autostart/$app.desktop" ] || continue
        f="$dir/$app.desktop"
        if [ -f "$f" ] && grep -q '^Hidden=true' "$f" 2>/dev/null; then
            ok "$app autostart already disabled"
            continue
        fi
        if [ "${KRK_DRY_RUN:-0}" = 1 ]; then
            printf '%s  would disable%s %s autostart for %s\n' \
                "$C_DIM" "$C_RESET" "$app" "$user"
            continue
        fi
        install -d -o "$user" -g "$grp" -m 0755 "$dir" || continue
        cat >"$f" <<EOF
[Desktop Entry]
Type=Application
Name=$app
Hidden=true
# Disabled by kali-rdp-kit. A screen lock inside an RDP session is a lockout
# risk rather than a security gain: the RDP layer has already authenticated,
# and the unlock dialog frequently cannot take keyboard focus under Xvnc.
EOF
        chown "$user:$grp" "$f"
        info "disabled $app autostart for $user"
    done
}

# krk_xfconf_set USER CHANNEL PROPERTY TYPE VALUE
#
# Apply an Xfce setting to a *running* session. A live xfconfd owns the
# settings in memory and rewrites its XML on exit, so editing those files
# underneath it is silently discarded -- this goes through xfconf-query
# instead. Returns 1 when the user has no live session, so callers can fall
# back to writing config for the next login.
krk_xfconf_set() {
    local user=$1 channel=$2 prop=$3 type=$4 value=$5 spid dbus disp
    have xfconf-query || return 1
    spid=$(pgrep -u "$user" -f xfce4-session 2>/dev/null | head -1) || return 1
    [ -n "$spid" ] || return 1
    dbus=$(krk_proc_env "$spid" DBUS_SESSION_BUS_ADDRESS) || return 1
    [ -n "$dbus" ] || return 1
    disp=$(krk_proc_env "$spid" DISPLAY)
    if [ "${KRK_DRY_RUN:-0}" = 1 ]; then
        printf '%s  would set%s %s %s=%s in the live session\n' \
            "$C_DIM" "$C_RESET" "$channel" "$prop" "$value"
        return 0
    fi
    runuser -u "$user" -- env DISPLAY="${disp:-:0}" DBUS_SESSION_BUS_ADDRESS="$dbus" \
        xfconf-query -c "$channel" -p "$prop" -n -t "$type" -s "$value" >/dev/null 2>&1
}

# Screen lockers that autostart on a Debian-family desktop. Any of these
# turns a dropped RDP connection into a lockout.
KRK_LOCKERS="xfce4-screensaver light-locker xscreensaver gnome-screensaver mate-screensaver"

krk_running_lockers() {
    # -f, not -x: "xfce4-screensaver" exceeds the 15-character comm name that
    # -x matches against, so -x silently finds nothing.
    local app pids out=""
    for app in $KRK_LOCKERS; do
        pids=$(pgrep -f "$app" 2>/dev/null | tr '\n' ' ')
        [ -n "$pids" ] && out="$out$app "
    done
    printf '%s' "$out"
}

krk_init_state() {
    KRK_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    export KRK_RUN_ID
    if [ "$(id -u)" -eq 0 ]; then
        run mkdir -p "$KRK_STATE_DIR"
    fi
}
