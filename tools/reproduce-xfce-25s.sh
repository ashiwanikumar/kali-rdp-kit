#!/usr/bin/env bash
#
# reproduce-xfce-25s.sh -- try to reproduce the Xfce ~25s session exit, and
# capture a usable trace if it happens.
#
# The bug (docs/xfce-25s.md): under xrdp's Xvnc backend an Xfce session starts,
# draws, and xfwm4 exits about 25 seconds later. It was reported as reproducible
# across clean rebuilds and has never been root-caused.
#
# Everything happens under a throwaway account on a spare display. The invoking
# user's own desktop is never touched -- which matters, because the obvious way
# to test this by hand is to restart your own session, and that is exactly how
# you lose the work you were using to investigate.
#
# Usage:  sudo ./tools/reproduce-xfce-25s.sh [--keep] [--display N] [--wait S]
#
# Exit status: 0 reproduced (a trace was captured), 1 not reproduced, 2 error.
#
set -uo pipefail

TEST_USER="${KRK_TEST_USER:-krk25probe}"
TEST_PASS="${KRK_TEST_PASS:-$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20)Aa1@}"
HOST_DISPLAY=61
WAIT_SECONDS=75
KEEP=0
OUTDIR="${KRK_TEST_OUTDIR:-/tmp/xfce-25s-probe}"

while [ $# -gt 0 ]; do
    case $1 in
        --keep)     KEEP=1 ;;
        --display)  HOST_DISPLAY=${2:?--display needs a number}; shift ;;
        --wait)     WAIT_SECONDS=${2:?--wait needs seconds}; shift ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *)          echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (it creates a throwaway user)" >&2; exit 2; }

for c in Xvnc xfreerdp3 xfce4-session useradd; do
    command -v "$c" >/dev/null 2>&1 || {
        echo "missing: $c" >&2
        echo "  need: tigervnc-standalone-server freerdp3-x11 xfce4" >&2
        exit 2; }
done

RDP_PORT=$(awk -F= '/^\[Globals\]/{g=1} g && /^port=/{print $2; exit}' /etc/xrdp/xrdp.ini 2>/dev/null)
RDP_PORT=${RDP_PORT:-3389}

mkdir -p "$OUTDIR"
echo "==> output: $OUTDIR"

cleanup() {
    [ "$KEEP" = 1 ] && { echo "==> --keep: leaving $TEST_USER and its session running"; return; }
    pkill -u "$TEST_USER" -9 2>/dev/null
    sleep 1
    pkill -f "Xvnc :$HOST_DISPLAY" 2>/dev/null
    rm -f "/tmp/.X${HOST_DISPLAY}-lock" "/tmp/.X11-unix/X${HOST_DISPLAY}" 2>/dev/null
    userdel -r "$TEST_USER" 2>/dev/null
    echo "==> cleaned up"
}
trap cleanup EXIT

# --- throwaway account, deliberately with a pristine profile ----------------
#
# No kali-rdp-profile tweaks: the point is to test Xfce as it ships, not Xfce
# as this kit configures it. A fix that only works on a profile we wrote is not
# a fix for the bug as reported.
if id "$TEST_USER" >/dev/null 2>&1; then
    echo "==> reusing existing $TEST_USER"
else
    useradd -m -s /bin/bash "$TEST_USER" || { echo "useradd failed" >&2; exit 2; }
fi
printf '%s:%s\n' "$TEST_USER" "$TEST_PASS" | chpasswd || { echo "chpasswd failed" >&2; exit 2; }
printf 'xfce4-session\n' >"/home/$TEST_USER/.xsession"
chown "$TEST_USER:$TEST_USER" "/home/$TEST_USER/.xsession"

# --- a spare X server purely to host the RDP client window ------------------
rm -f "/tmp/.X${HOST_DISPLAY}-lock" "/tmp/.X11-unix/X${HOST_DISPLAY}" 2>/dev/null
Xvnc ":$HOST_DISPLAY" -geometry 1400x900 -depth 16 -SecurityTypes None \
    -localhost -nolisten tcp >"$OUTDIR/host-xvnc.log" 2>&1 &
sleep 3

# --- the real thing: a genuine RDP login through xrdp -----------------------
#
# Driving xrdp rather than starting Xvnc by hand is the whole point. xrdp's
# path runs startwm.sh, /etc/X11/Xsession, PAM (and so pam_systemd, and so a
# logind session), and xrdp-chansrv. A hand-rolled Xvnc skips all of it, and
# every one of those is a candidate for whatever is timing out.
echo "==> connecting to localhost:$RDP_PORT as $TEST_USER"
DISPLAY=":$HOST_DISPLAY" xfreerdp3 "/v:localhost:$RDP_PORT" "/u:$TEST_USER" "/p:$TEST_PASS" \
    /cert:ignore /size:1280x800 /bpp:16 -grab-keyboard /log-level:ERROR \
    >"$OUTDIR/rdp-client.log" 2>&1 &
CLIENT_PID=$!

# --- watch, and trace the moment it appears ---------------------------------
appeared=""
wm_pid=""
for i in $(seq 1 "$WAIT_SECONDS"); do
    sleep 1
    p=$(pgrep -u "$TEST_USER" -x xfwm4 2>/dev/null | head -1)
    if [ -n "$p" ]; then
        if [ -z "$appeared" ]; then
            appeared=$i; wm_pid=$p
            echo "    t=${i}s  xfwm4 up (pid $p)"
            # Attach now: if it dies at 25s the interesting syscall is already
            # in flight, and a trace started after the fact captures nothing.
            if command -v strace >/dev/null 2>&1; then
                strace -f -tt -T -p "$p" -o "$OUTDIR/xfwm4.strace" 2>/dev/null &
                echo "    attached strace -> $OUTDIR/xfwm4.strace"
            fi
            command -v dbus-monitor >/dev/null 2>&1 && \
                runuser -u "$TEST_USER" -- dbus-monitor --session \
                    >"$OUTDIR/dbus-session.log" 2>&1 &
        fi
    elif [ -n "$appeared" ]; then
        lived=$(( i - appeared ))
        echo
        echo "*** REPRODUCED: xfwm4 exited after ${lived}s ***"
        {
            echo "lived_seconds=$lived"
            echo "xfwm4_pid=$wm_pid"
            echo "xfce4_session_still_running=$(pgrep -u "$TEST_USER" -x xfce4-session >/dev/null && echo yes || echo no)"
            echo "--- versions ---"
            dpkg-query -W -f='${Package} ${Version}\n' xfwm4 xfce4-session xrdp \
                tigervnc-standalone-server libdbus-1-3 2>/dev/null
            echo "--- logind ---"
            loginctl list-sessions --no-legend 2>/dev/null | grep "$TEST_USER"
        } >"$OUTDIR/summary.txt" 2>&1
        sleep 2; pkill -f "strace -f -tt -T -p $wm_pid" 2>/dev/null
        echo
        echo "syscalls that blocked for more than a second:"
        awk '{ if (match($0, /<([0-9.]+)>$/)) { t = substr($0, RSTART+1, RLENGTH-2);
               if (t+0 > 1.0) print "    " $0 } }' "$OUTDIR/xfwm4.strace" 2>/dev/null | tail -20
        echo
        echo "25s is libdbus's default reply timeout, so a poll/ppoll/recvmsg on a"
        echo "D-Bus socket above is the call to chase."
        echo "Attach $OUTDIR/ to the issue."
        kill "$CLIENT_PID" 2>/dev/null
        exit 0
    fi
done

echo
echo "not reproduced: xfwm4 survived ${WAIT_SECONDS}s"
{
    echo "result=not-reproduced"
    echo "waited_seconds=$WAIT_SECONDS"
    dpkg-query -W -f='${Package} ${Version}\n' xfwm4 xfce4-session xrdp \
        tigervnc-standalone-server libdbus-1-3 2>/dev/null
} >"$OUTDIR/summary.txt" 2>&1
kill "$CLIENT_PID" 2>/dev/null
exit 1
