# If I close the RDP window, do my apps stay open?

**Yes — closing an RDP client disconnects, it does not log out.** Your desktop,
your window manager, and every application you opened keep running on the
server. Reconnect and you land back in the same desktop with the same windows.

Only two things end a session and close your apps:

1. **Logging out** from inside the desktop (or `reboot`/`shutdown`).
2. **Something reaping it** — which on Kali means `kali-rdp-cleanup`, and
   nothing else. See below.

## How long do they stay open?

By default, **30 minutes after you disconnect**, `kali-rdp-cleanup` reaps the
session and your apps die with it. Change it with `--grace`, or by editing
`KRK_GRACE_SECONDS` in the service unit:

```bash
sudo systemctl edit kali-rdp-cleanup.service
```

```ini
[Service]
Environment=KRK_GRACE_SECONDS=86400     # keep parked sessions for a day
```

Set it very high and disconnected sessions effectively persist forever. The
orphaned *helpers* (chansrv, pipewire) are still reaped immediately, because
those are unambiguous garbage — a helper whose X server is already gone.

## The part that surprises people

You would expect xrdp itself to handle this via `sesman.ini`:

```ini
KillDisconnected=true
DisconnectedTimeLimit=1800
```

**On Kali these do nothing.** From `sesman.ini(5)`:

> KillDisconnected … This setting currently only works with xorgxrdp sessions.

The same note applies to `DisconnectedTimeLimit`. Kali has no `xorgxrdp`
package, so every Kali install runs the Xvnc backend, where both keys are
parsed, stored, and ignored.

So a `sesman.ini` that looks perfectly tuned will still let sessions pile up
indefinitely. `kali-rdp-doctor` reports these keys as *inert* rather than as a
pass, specifically so this is not mistaken for a working configuration.

## "I reconnected and all my windows were gone"

Usually this does not mean your apps were killed. It means you were given a
**different session**, while the old one — with your windows in it — is still
running, disconnected.

`Policy` in `sesman.ini` decides when a connection rejoins an existing session
versus starting a new one. `Policy=Default` is equivalent to `UB`:

| Letter | Sessions are separated by | Can it be disabled? |
|---|---|---|
| `U` | user | no |
| `B` | bits-per-pixel (colour depth) | no |
| `D` | initial display size | yes |
| `I` | client IP address | yes |

Because `B` cannot be turned off, **connecting with a client negotiating a
different colour depth starts a brand-new desktop.** Reconnecting from a
different device, or from a client configured for 16-bit instead of 32-bit
colour, is enough to do it.

That is the usual cause of both symptoms at once: your windows "vanish", *and*
sessions accumulate. Check with:

```bash
kali-rdp-doctor          # section 6 lists every session and whether it is attached
```

If you see several sessions for one user, the disconnected ones hold your
missing windows. Reconnect with the same colour depth to get back into one.

Adding `D` or `I` to `Policy` makes this much worse — `I` means reconnecting
from a different network gives you a new desktop every time. `kali-rdp-doctor`
warns if either is set.

## What survives even when the session is reaped

Killing the X server does not kill everything the user owns. Debian and Kali
ship `KillUserProcesses=no` in `logind.conf`, and `kali-rdp-cleanup` only
signals the session's own processes.

| | Survives a reaped session? |
|---|---|
| GUI applications | **No** — they lose the X connection and exit |
| `tmux` / `screen` sessions | **Yes** — the server is not an X client |
| `nohup`, `setsid`, `disown`ed jobs | **Yes** |
| systemd user services (with `loginctl enable-linger`) | **Yes** |

This is the practical argument for running long jobs inside `tmux` rather than
in a desktop terminal. A scan or build started in a plain terminal window dies
with the desktop; the same command inside `tmux` does not, and you can pick it
up again from SSH without RDP at all.

`kali-ssh-setup` installs the tmux auto-attach snippet for exactly this reason.

## Summary

| Action | Apps keep running? |
|---|---|
| Close the RDP client window | Yes |
| Network drops | Yes |
| Reconnect within the grace period | Yes — same desktop, same windows |
| Reconnect with a different colour depth | Old session survives, but you get a new desktop |
| Disconnected longer than the grace period | No — reaped |
| Log out from the desktop menu | No |
