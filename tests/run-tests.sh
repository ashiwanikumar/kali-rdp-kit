#!/usr/bin/env bash
#
# Regression tests for kali-rdp-kit.
#
# Every test here exists because something was reported as broken. The point is
# not coverage for its own sake: it is that a check which once cried wolf, or
# once stayed silent about a real fault, cannot quietly go back to doing so.
#
# Runs anywhere bash, awk and coreutils exist -- no xrdp, no root, no systemd.
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KRK_LIB="$ROOT/lib"
export KRK_LIB

PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Keep every side effect inside the temp dir: the suite must be runnable by an
# ordinary user without writing to /var/lib.
export KRK_STATE_DIR="$TMP/state"
export KRK_BACKUP_DIR="$TMP/state/backups"

grn=$'\033[32m'; red=$'\033[31m'; rst=$'\033[0m'
[ -t 1 ] || { grn=; red=; rst=; }

check() {
    local what=$1 got=$2 want=$3
    if [ "$got" = "$want" ]; then
        PASS=$(( PASS + 1 ))
        printf '  %sok%s   %s\n' "$grn" "$rst" "$what"
    else
        FAIL=$(( FAIL + 1 ))
        printf '  %sFAIL%s %s\n       want: %s\n       got:  %s\n' \
            "$red" "$rst" "$what" "$want" "$got"
    fi
}

contains() {
    local what=$1 haystack=$2 needle=$3
    case $haystack in
        *"$needle"*) PASS=$(( PASS + 1 )); printf '  %sok%s   %s\n' "$grn" "$rst" "$what" ;;
        *) FAIL=$(( FAIL + 1 ))
           printf '  %sFAIL%s %s\n       expected to contain: %s\n' "$red" "$rst" "$what" "$needle" ;;
    esac
}

lacks() {
    local what=$1 haystack=$2 needle=$3
    case $haystack in
        *"$needle"*) FAIL=$(( FAIL + 1 ))
           printf '  %sFAIL%s %s\n       must NOT contain: %s\n' "$red" "$rst" "$what" "$needle" ;;
        *) PASS=$(( PASS + 1 )); printf '  %sok%s   %s\n' "$grn" "$rst" "$what" ;;
    esac
}

section() { printf '\n%s\n' "$1"; }

# shellcheck source=../lib/common.sh
. "$KRK_LIB/common.sh"

# ---------------------------------------------------------------------------
section "log scoping (the stale-FAIL bug: a doctor that grepped the whole log)"

# Two stamp formats, because xrdp changed its own in 0.10 and both are in the
# wild on hosts that have been upgraded.
cat >"$TMP/iso.log" <<'EOF'
[2026-08-02T08:20:43.855+0400] [ERROR] Cannot read private key file /etc/xrdp/key.pem: Permission denied
[2026-08-02T08:20:44.000+0400] [INFO ] old news
[2026-08-06T05:00:00.000+0400] [INFO ] xrdp starting
[2026-08-06T05:00:01.000+0400] [INFO ] all is well
EOF
cat >"$TMP/legacy.log" <<'EOF'
[20260802-08:20:43] [ERROR] Cannot read private key file /etc/xrdp/key.pem: Permission denied
[20260806-05:00:00] [INFO ] xrdp starting
EOF

cutoff=$(date -d '2026-08-06 04:59:00' +%s 2>/dev/null)
if [ -z "$cutoff" ]; then
    echo "  skip: this platform's date(1) cannot parse an absolute date"
else
    out=$(krk_log_since "$TMP/iso.log" "$cutoff")
    lacks "ISO stamps: an error from four days ago is outside the window" \
        "$out" "Cannot read private key"
    contains "ISO stamps: current lines are inside the window" "$out" "all is well"

    out=$(krk_log_since "$TMP/legacy.log" "$cutoff")
    lacks "legacy stamps: old error excluded" "$out" "Cannot read private key"
    contains "legacy stamps: current line included" "$out" "xrdp starting"

    # A wrapped line carries no stamp of its own; dropping it would cut a
    # traceback in half and hide the part that names the fault.
    cat >"$TMP/cont.log" <<'EOF'
[2026-08-02T08:20:43.855+0400] [ERROR] ancient
    ancient continuation
[2026-08-06T05:00:00.000+0400] [ERROR] current
    current continuation
EOF
    out=$(krk_log_since "$TMP/cont.log" "$cutoff")
    contains "continuation line inherits its parent's verdict" "$out" "current continuation"
    lacks    "old continuation line stays excluded" "$out" "ancient continuation"

    # Scoping must never silently swallow a log it cannot parse: reporting
    # "no errors" about a file you failed to read is the same lie as before.
    printf 'no timestamps here at all\nsomething broke\n' >"$TMP/plain.log"
    out=$(krk_log_since "$TMP/plain.log" "$cutoff")
    contains "unparseable log degrades to showing everything" "$out" "something broke"

    krk_log_since "$TMP/does-not-exist.log" "$cutoff" >/dev/null 2>&1
    check "missing log is an error, not an empty result" "$?" "1"

    # Logrotate can move the start of the window into the previous file.
    cat >"$TMP/rot.log" <<'EOF'
[2026-08-06T05:10:00.000+0400] [INFO ] after rotation
EOF
    cat >"$TMP/rot.log.1" <<'EOF'
[2026-08-02T08:00:00.000+0400] [ERROR] far too old
[2026-08-06T05:00:30.000+0400] [ERROR] just before rotation
EOF
    out=$(krk_log_since "$TMP/rot.log" "$cutoff")
    contains "rotated file is consulted when the live one starts late" "$out" "just before rotation"
    contains "live file is still read"                                 "$out" "after rotation"
    lacks    "rotation lookup still respects the cutoff"               "$out" "far too old"
fi

# ---------------------------------------------------------------------------
section "session inventory"

# A fake ps(1) lets the parsing be tested without running an X server.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/ps" <<'EOF'
#!/bin/sh
cat "$FAKE_PS"
EOF
chmod +x "$TMP/bin/ps"

cat >"$TMP/ps.normal" <<'EOF'
 1001 999 Xvnc :22 -auth .Xauthority -geometry 1920x1080 -depth 16 -rfbauth /home/u/.vnc/sesman_passwd-u@kali:22 -bs -nolisten tcp -localhost -dpi 96
 1002 1 Xvnc :5 -geometry 800x600 -depth 24 -rfbauth /home/u/.vnc/passwd -localhost
EOF
out=$(PATH="$TMP/bin:$PATH" FAKE_PS="$TMP/ps.normal" krk_xvnc_inventory)
check "two servers found" "$(printf '%s' "$out" | grep -c .)" "2"
contains "xrdp-started server is classified sesman" "$out" $'1001\t22\t16\t1920x1080\tsesman'
contains "hand-started server is classified standalone -- never ours to reap" \
    "$out" $'1002\t5\t24\t800x600\tstandalone'

# An Xvnc that daemonises is briefly visible twice. Counting it twice would
# double-count desktops and send a reaper after a pid that is already gone.
cat >"$TMP/ps.fork" <<'EOF'
 2001 500 Xvnc :59 -geometry 800x600 -depth 24 -rfbauth /home/u/.vnc/sesman_passwd-u@kali:59 -localhost
 2002 2001 Xvnc :59 -geometry 800x600 -depth 24 -rfbauth /home/u/.vnc/sesman_passwd-u@kali:59 -localhost
EOF
out=$(PATH="$TMP/bin:$PATH" FAKE_PS="$TMP/ps.fork" krk_xvnc_inventory)
check "a forking Xvnc is reported once, not twice" "$(printf '%s' "$out" | grep -c .)" "1"
contains "the surviving child is the one kept" "$out" "2002"

out=$(PATH="$TMP/bin:$PATH" FAKE_PS="$TMP/ps.normal" krk_xvnc_sessions)
check "krk_xvnc_sessions shares the inventory's view" "$out" "$(printf '1001 22\n1002 5')"

# A display written with a leading zero must not be read as octal.
check "display :08 resolves to port 5908, not an arithmetic error" \
    "$( (krk_display_connected 08; echo "rc=$?") 2>&1 | grep -c 'value too great\|invalid' )" "0"

# ---------------------------------------------------------------------------
section "orphan detection (a desktop sesman has forgotten)"

# Structure, not descent: everything a user runs inside their desktop is also a
# descendant of sesman, so a descent test would call every hand-started X
# server "tracked" and never report the fault this exists to find.
_tracked_case() {
    krk_sesman_pid() { printf '900'; }
    krk_pid_ppid()   { case $1 in 1001) printf '950' ;; 950) printf '900' ;; esac; }
    krk_pid_comm()   { case $1 in 950) printf 'xrdp-sesexec' ;; esac; }
    krk_session_orphaned 1001 && printf 'orphaned' || printf 'tracked'
}
check "Xvnc -> sesexec -> sesman is tracked" "$(_tracked_case)" "tracked"

_orphan_case() {
    krk_sesman_pid() { printf '900'; }
    krk_pid_ppid()   { case $1 in 1001) printf '1' ;; esac; }
    krk_pid_comm()   { printf 'systemd'; }
    krk_session_orphaned 1001 && printf 'orphaned' || printf 'tracked'
}
check "Xvnc reparented to init is orphaned" "$(_orphan_case)" "orphaned"

_shell_case() {
    # A shell inside the desktop: descended from sesman, but its parent is not
    # sesexec. The old descent-based test got this wrong.
    krk_sesman_pid() { printf '900'; }
    krk_pid_ppid()   { case $1 in 1001) printf '1500' ;; 1500) printf '900' ;; esac; }
    krk_pid_comm()   { case $1 in 1500) printf 'bash' ;; esac; }
    krk_session_orphaned 1001 && printf 'orphaned' || printf 'tracked'
}
check "an X server launched from a shell in the desktop is NOT tracked" \
    "$(_shell_case)" "orphaned"

_old_xrdp_case() {
    # Before xrdp-sesexec existed, sesman forked the session itself.
    krk_sesman_pid() { printf '900'; }
    krk_pid_ppid()   { case $1 in 1001) printf '900' ;; esac; }
    krk_pid_comm()   { printf 'xrdp-sesman'; }
    krk_session_orphaned 1001 && printf 'orphaned' || printf 'tracked'
}
check "older xrdp (no sesexec) is still recognised as tracked" "$(_old_xrdp_case)" "tracked"

_no_sesman_case() {
    krk_sesman_pid() { printf ''; }
    krk_session_orphaned 1001 && printf 'orphaned' || printf 'tracked'
}
check "with no sesman running, nothing is tracked" "$(_no_sesman_case)" "orphaned"

# ---------------------------------------------------------------------------
section "TLS certificate"

if command -v openssl >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/self.key" -out "$TMP/self.pem" \
        -days 365 -nodes -subj "/CN=test" >/dev/null 2>&1
    krk_cert_self_signed "$TMP/self.pem"
    check "a self-signed certificate is recognised" "$?" "0"

    days=$(krk_cert_days_left "$TMP/self.pem")
    if [ "${days:-0}" -gt 360 ] && [ "${days:-0}" -le 365 ]; then
        PASS=$(( PASS + 1 )); printf '  %sok%s   remaining validity is computed\n' "$grn" "$rst"
    else
        FAIL=$(( FAIL + 1 )); printf '  %sFAIL%s remaining validity: got %s, want ~365\n' "$red" "$rst" "$days"
    fi

    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/exp.key" -out "$TMP/exp.pem" \
        -days 1 -not_before 20200101000000Z -not_after 20200102000000Z \
        -nodes -subj "/CN=expired" >/dev/null 2>&1 \
      || openssl req -x509 -newkey rsa:2048 -keyout "$TMP/exp.key" -out "$TMP/exp.pem" \
        -days -1 -nodes -subj "/CN=expired" >/dev/null 2>&1
    if [ -s "$TMP/exp.pem" ]; then
        days=$(krk_cert_days_left "$TMP/exp.pem")
        if [ "${days:-1}" -lt 0 ]; then
            PASS=$(( PASS + 1 )); printf '  %sok%s   an expired certificate reports negative days\n' "$grn" "$rst"
        else
            FAIL=$(( FAIL + 1 )); printf '  %sFAIL%s expired certificate reported %s days\n' "$red" "$rst" "$days"
        fi
    fi
    # Integer division truncates toward zero, so a certificate that went out of
    # date an hour ago must not come back as "0 days left" and be reported as
    # merely expiring soon.
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/j.key" -out "$TMP/j.pem" \
        -nodes -subj "/CN=just-expired" \
        -not_before "$(date -u -d '2 days ago'  +%Y%m%d%H%M%SZ)" \
        -not_after  "$(date -u -d '1 hour ago'  +%Y%m%d%H%M%SZ)" >/dev/null 2>&1
    if [ -s "$TMP/j.pem" ]; then
        days=$(krk_cert_days_left "$TMP/j.pem")
        check "expired an hour ago reads as -1 day, not 0" "$days" "-1"
    else
        echo "  skip: this openssl cannot backdate a certificate"
    fi
else
    echo "  skip: no openssl"
fi

# The snakeoil pair must be recognised without openssl, by path, because that
# combination with security_layer=negotiate is the fault worth warning about.
mkdir -p "$TMP/ssl/certs" "$TMP/etc"
: >"$TMP/ssl/certs/ssl-cert-snakeoil.pem"
ln -sf "$TMP/ssl/certs/ssl-cert-snakeoil.pem" "$TMP/etc/cert.pem"
krk_cert_self_signed "$TMP/etc/cert.pem"
check "snakeoil is recognised through a symlink, with no openssl call" "$?" "0"

# ---------------------------------------------------------------------------
section "path and permission probes"

ln -sf /nonexistent/unreachable/key.pem "$TMP/dangling.pem"
krk_path_present "$TMP/dangling.pem"
check "a symlink whose target cannot be reached still counts as present" "$?" "0"
krk_path_present "$TMP/definitely-absent"
check "an absent path is absent" "$?" "1"

if [ "$(id -u)" -ne 0 ]; then
    krk_can_read_as nobody /etc/hostname
    check "unprivileged: 'could not test' (2), never a bare 'unreadable'" "$?" "2"
fi

# ---------------------------------------------------------------------------
section "ini editing"

cat >"$TMP/test.ini" <<'EOF'
[Globals]
port=3389
;security_layer=negotiate

[Xvnc]
param=-localhost
EOF
check "reads a plain key"            "$(ini_get "$TMP/test.ini" Globals port)" "3389"
check "a commented key reads empty"  "$(ini_get "$TMP/test.ini" Globals security_layer)" ""
check "keys are scoped to a section" "$(ini_get "$TMP/test.ini" Xvnc port)" ""

ini_set "$TMP/test.ini" Globals security_layer tls
check "setting a key uncomments it in place" \
    "$(ini_get "$TMP/test.ini" Globals security_layer)" "tls"
ini_set "$TMP/test.ini" Globals security_layer tls
check "re-setting the same value reports no change" "$?" "1"
check "the other section survived the rewrite" \
    "$(ini_get "$TMP/test.ini" Xvnc param)" "-localhost"

# ---------------------------------------------------------------------------
section "doctor end to end"

DOC="$ROOT/bin/kali-rdp-doctor"
mkdir -p "$TMP/xrdp"
cat >"$TMP/xrdp/xrdp.ini" <<'EOF'
[Globals]
port=3389
runtime_user=xrdp
security_layer=negotiate
crypt_level=high
ssl_protocols=TLSv1.2, TLSv1.3
certificate=
key_file=

[Xvnc]
name=Xvnc
EOF
cat >"$TMP/xrdp/sesman.ini" <<'EOF'
[Sessions]
KillDisconnected=false
Policy=Default
EOF
ln -sf "$TMP/ssl/certs/ssl-cert-snakeoil.pem" "$TMP/xrdp/cert.pem"
: >"$TMP/xrdp/key.pem"

# The regression that matters most: an error the log remembers from before the
# running xrdp started must not be reported as a live fault.
cat >"$TMP/xrdp.log" <<'EOF'
[2020-01-01T00:00:00.000+0000] [ERROR] Cannot read private key file /etc/xrdp/key.pem: Permission denied
EOF
: >"$TMP/sesman.log"

out=$(KRK_XRDP_DIR="$TMP/xrdp" KRK_XRDP_LOG="$TMP/xrdp.log" \
      KRK_SESMAN_LOG="$TMP/sesman.log" NO_COLOR=1 "$DOC" 2>&1)
rc=$?
lacks "a years-old key error is not reported as a current failure" \
    "$out" "FAIL xrdp.log reports it cannot read the private key"
contains "it is reported as history instead" "$out" "already resolved"
contains "negotiate + self-signed is warned about" \
    "$out" "known cause of intermittent handshake failures"
if [ "$rc" -le 2 ]; then
    PASS=$(( PASS + 1 )); printf '  %sok%s   doctor exits with a defined status (%s)\n' "$grn" "$rst" "$rc"
else
    FAIL=$(( FAIL + 1 )); printf '  %sFAIL%s doctor crashed (rc=%s)\n' "$red" "$rst" "$rc"
fi

out=$(KRK_XRDP_DIR="$TMP/xrdp" KRK_XRDP_LOG="$TMP/xrdp.log" \
      KRK_SESMAN_LOG="$TMP/sesman.log" "$DOC" --json 2>/dev/null)
if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["tls"]["security_layer"]=="negotiate" and d["tls"]["self_signed"] is True else 1)' 2>/dev/null; then
    PASS=$(( PASS + 1 )); printf '  %sok%s   --json is parseable and reports the TLS posture\n' "$grn" "$rst"
else
    FAIL=$(( FAIL + 1 )); printf '  %sFAIL%s --json malformed or missing the tls block\n' "$red" "$rst"
fi

# With the layer pinned, the warning must go away -- a check that fires either
# way teaches people to ignore it.
sed -i 's/^security_layer=.*/security_layer=tls/' "$TMP/xrdp/xrdp.ini"
out=$(KRK_XRDP_DIR="$TMP/xrdp" KRK_XRDP_LOG="$TMP/xrdp.log" \
      KRK_SESMAN_LOG="$TMP/sesman.log" NO_COLOR=1 "$DOC" 2>&1)
lacks "security_layer=tls clears the warning" \
    "$out" "known cause of intermittent handshake failures"

# An unreadable log must be reported as unreadable, never as "all clear".
if [ "$(id -u)" -ne 0 ]; then
    printf 'x\n' >"$TMP/secret.log"; chmod 000 "$TMP/secret.log"
    out=$(KRK_XRDP_DIR="$TMP/xrdp" KRK_XRDP_LOG="$TMP/secret.log" \
          KRK_SESMAN_LOG="$TMP/sesman.log" NO_COLOR=1 "$DOC" 2>&1)
    contains "an unreadable log says so rather than passing silently" "$out" "not readable"
    chmod 644 "$TMP/secret.log"
fi

# ---------------------------------------------------------------------------
section "cleanup argument guards"

CLEAN="$ROOT/bin/kali-rdp-cleanup"
out=$(NO_COLOR=1 "$CLEAN" --grace banana 2>&1); rc=$?
check "a non-numeric grace is refused rather than guessed at" "$rc" "1"
contains "and says why" "$out" "must be a number of seconds"

out=$(NO_COLOR=1 "$CLEAN" --kill nope 2>&1); rc=$?
check "--kill demands a display number" "$rc" "1"

out=$(NO_COLOR=1 "$CLEAN" --frobnicate 2>&1); rc=$?
check "an unknown option is rejected" "$rc" "2"

# ---------------------------------------------------------------------------
section "setup argument guards"

SETUP="$ROOT/bin/kali-rdp-setup"
out=$(NO_COLOR=1 "$SETUP" --security-layer sideways 2>&1); rc=$?
check "an invalid security layer is refused" "$rc" "1"
contains "and lists the valid ones" "$out" "tls, negotiate or rdp"

out=$(NO_COLOR=1 "$SETUP" --max-bpp 7 2>&1); rc=$?
check "an invalid colour depth is refused" "$rc" "1"

# ---------------------------------------------------------------------------
printf '\n%s%d passed, %d failed%s\n' \
    "$([ "$FAIL" -eq 0 ] && printf '%s' "$grn" || printf '%s' "$red")" \
    "$PASS" "$FAIL" "$rst"
[ "$FAIL" -eq 0 ]
