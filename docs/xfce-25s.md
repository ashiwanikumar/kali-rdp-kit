# Xfce sessions exiting ~25 seconds after start

**Status: open, not root-caused.** Openbox is the current workaround.

## Symptom

Under xrdp's Xvnc backend, an Xfce session starts, draws, and then `xfwm4`
exits roughly 25 seconds later. The window manager goes first; the rest of the
session follows or is left unusable. Reproducible across clean rebuilds. The
same Xfce install on a console session does not do this.

## Why the timing matters

25 seconds, consistently, is not what a crash looks like. Crashes cluster
around a triggering action, not a stopwatch. A fixed interval points at a
*timeout* — something waiting on a reply that never arrives and giving up.

The usual candidates in an Xfce startup sequence:

- `xfsettingsd` / `xfconfd` autostart over the session D-Bus bus
- a polkit authorization check with no agent available to answer it
- `xfce4-session`'s own client-registration timeout (ICE / session management)
- `gnome-keyring` or an agent socket already owned by another session

The RDP-specific angle: under Xvnc there is no seat-attached login session, so
`logind` may not consider the session active, and polkit calls that would
normally auto-approve instead block until they time out.

## Capturing a useful trace

The trace needs to cover the whole startup window, and `xfwm4` forks, so `-f`
is required. Timestamps are what make it readable — without `-t` you cannot
find the 25-second mark.

Inside a fresh RDP session, with Xfce as the session type:

```bash
# -f follow forks, -t timestamps, -T time spent in each call
strace -f -tt -T -o /tmp/xfwm4-trace.log xfwm4 --replace
```

Let it die, then find where the gap is:

```bash
# Any single syscall that took more than a second
awk '{ if (match($0, /<([0-9.]+)>$/)) { t = substr($0, RSTART+1, RLENGTH-2); if (t+0 > 1.0) print } }' \
    /tmp/xfwm4-trace.log
```

The call that blocks for ~25s, and whatever it is talking to, is the answer.
A `poll`/`ppoll`/`recvmsg` on a D-Bus socket would confirm the timeout theory.

Worth capturing alongside:

```bash
# session bus traffic during startup
dbus-monitor --session >/tmp/dbus-session.log 2>&1 &

# whether logind considers the session active
loginctl session-status

# xfce's own view
xfce4-session-logout --help >/dev/null; journalctl --user -b -n 200
```

Also useful: `XFSM_VERBOSE=1` in the session environment makes
`xfce4-session` log its client registration and timeout decisions.

## Ruling things out

- If `xfwm4 --replace` under a **plain `Xvnc` started by hand** (no xrdp)
  survives past 25s, the problem is in xrdp's session setup, not Xvnc.
- If it dies there too, it is Xvnc + Xfce, and xrdp is incidental.

That single test splits the search space in half and is worth doing first.

## Contributing a fix

A trace showing the blocking call, plus the output of `loginctl session-status`
from inside the failing session, is enough to open a useful issue.
