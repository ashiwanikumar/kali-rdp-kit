# Xfce sessions exiting ~25 seconds after start

**Status: reported, not root-caused, and not reproducible on current packages.**
Openbox remains the conservative choice, but the evidence for steering away from
Xfce is weaker than it was.

## Symptom

Under xrdp's Xvnc backend, an Xfce session starts, draws, and then `xfwm4`
exits roughly 25 seconds later. The window manager goes first; the rest of the
session follows or is left unusable. Reported as reproducible across clean
rebuilds. The same Xfce install on a console session does not do this.

## What 25 seconds tells you

25 seconds is not a round number somebody chose. It is **libdbus's default
method-call reply timeout** — `_DBUS_DEFAULT_TIMEOUT_VALUE`, 25000 ms — used by
every `dbus_connection_send_with_reply()` that does not pass an explicit
timeout.

So the shape of the bug is almost certainly: something in the Xfce startup makes
a D-Bus method call, nothing ever replies, libdbus gives up at 25s, and the
caller treats the failure as fatal. That is a much smaller search space than
"some timeout somewhere", and it means the thing to find is **a D-Bus call with
no responder**, not a crash.

Crashes cluster around a triggering action. Stopwatches point at timeouts.

## Reproducing it

```bash
sudo ./tools/reproduce-xfce-25s.sh
```

It creates a throwaway account with a pristine profile, logs in over RDP
*through xrdp* rather than starting Xvnc by hand, watches `xfwm4`, and — if it
dies — attaches `strace` and `dbus-monitor` before the interesting syscall is
over, then prints every call that blocked for more than a second.

Exit status: 0 reproduced (trace in `/tmp/xfce-25s-probe/`), 1 not reproduced.

Two details in there are deliberate and worth keeping if you rewrite it:

- **It never touches your own session.** The obvious way to test this by hand is
  to restart your own desktop, which is how you lose the work you were using to
  investigate.
- **It goes through xrdp, not straight to Xvnc.** xrdp's path runs
  `startwm.sh`, `/etc/X11/Xsession`, PAM (and so `pam_systemd`, and so a logind
  session), and `xrdp-chansrv`. A hand-rolled Xvnc skips all of it, and every
  one of those is a candidate for whatever is not answering.
- **The test account gets no `kali-rdp-profile` tweaks.** A fix that only works
  on a profile this kit wrote is not a fix for the bug as reported.

## What has been ruled out

Tested 2026-08-06 on Kali under vCenter, Xvnc backend, no `xorgxrdp`:

| Condition | Result |
|---|---|
| Real RDP login through xrdp, clean profile, fresh user | survived 75s |
| Hand-started Xvnc, isolated session bus, no `XDG_RUNTIME_DIR` | survived 60s |
| Two Xfce sessions for one user sharing the user bus and `~/.ICEauthority` | both survived 55s |
| The maintainer's own Xfce session, in normal use | `xfwm4` alive 2h+ |

Versions: `xfwm4` 4.20.0-1, `xfce4-session` 4.20.4-1, `xrdp` 0.10.6.1-2+kali1,
`tigervnc-standalone-server` 1.15.0+dfsg-2.1, `libdbus-1-3` 1.16.2-5+b1.

So on a host this kit has configured, with these versions, the bug does not
occur. That is not the same as fixed — see below.

## The leading untested hypothesis

**A console display-manager session on `:0` competing with the RDP session.**

This is the one condition that was *not* tested, and it is the one that best
fits the original report:

- It explains "the same Xfce install on a console session does not do this" —
  the console session is the one that wins, so it is not the one that dies.
- A console session owns the user's D-Bus session bus, `~/.ICEauthority`, and
  the agent sockets. A second, non-seat session then makes calls that the
  first session's daemons have no reason to answer. That is precisely a D-Bus
  call with no responder, which is precisely a 25-second timeout.
- `kali-rdp-setup` disables `lightdm`/`gdm3`/`sddm` and switches the default
  target to `multi-user`. **If this hypothesis is right, the kit has been
  fixing the bug since 0.1.0 without anyone connecting the two**, and the
  reason it no longer reproduces is that the fix is already applied.

It was not tested because testing it means enabling a display manager and
starting a console session on a box someone is working on over RDP — and if it
auto-logs-in the same user, the collision under test would take out the live
desktop. Worth doing on a scratch host; not worth doing on yours.

To test it there: enable `lightdm`, reboot to `graphical.target`, log in at the
console as the same user, then connect over RDP and run the probe script.

## If you reproduce it

Attach the whole of `/tmp/xfce-25s-probe/` to an issue. The three things that
matter:

- `xfwm4.strace` — the blocking call. A `poll`/`ppoll`/`recvmsg` on a D-Bus
  socket lasting ~25s confirms the timeout theory and names the peer.
- `dbus-session.log` — the method call that went unanswered.
- `summary.txt` — versions and the logind view of the session.

Also useful, from inside a failing session: `XFSM_VERBOSE=1` makes
`xfce4-session` log its client registration and timeout decisions, and
`loginctl session-status` shows whether logind considers the session active.
