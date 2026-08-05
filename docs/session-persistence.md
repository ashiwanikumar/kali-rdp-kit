# If I close the RDP window, do my apps stay open?

**Yes — closing an RDP client disconnects, it does not log out.** Your desktop,
your window manager, and every application you opened keep running on the
server. Reconnect and you land back in the same desktop with the same windows.

## How long do they stay open?

**Indefinitely.** Desktops are persistent by default: disconnect on Friday,
reconnect on Monday, and your windows are where you left them. Nothing in this
toolkit closes a desktop you have not logged out of.

Only two things close your apps:

1. **Logging out** from inside the desktop (or `reboot`/`shutdown`).
2. **Opting in to reaping** — off by default, see below.

Orphaned *helpers* (chansrv, pipewire) are still reaped immediately. Those are
unambiguous garbage: a helper whose X server is already gone, holding a VNC
port that makes the next session fail to bind with `errno=98`. Reaping them
never touches a running desktop.

### Opting in to closing idle desktops

On a shared box, parked desktops cost RAM and you may want them reclaimed:

```bash
sudo kali-rdp-setup --reap-disconnected 86400    # close after a day idle
```

This is a deliberate opt-in because **it closes users' applications**. Even
then it keys on whether a client is attached, never on uptime, so a desktop
somebody is actively using is never a candidate. Undo it by re-running plain
`sudo kali-rdp-setup`.

### The cost of persistence

Nothing closes desktops, so a client that keeps starting *new* sessions instead
of rejoining will accumulate them until the machine runs out of memory. The
usual cause is the colour-depth rule described below. `kali-rdp-doctor` warns
once three or more parked desktops exist.

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

## What survives if a desktop does end

Killing the X server does not kill everything the user owns. Debian and Kali
ship `KillUserProcesses=no` in `logind.conf`, and `kali-rdp-cleanup` only
signals the session's own processes.

| | Survives the desktop ending? |
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
| Reconnect days later | Yes — same desktop, same windows |
| Reconnect with a different colour depth | Old session survives, but you get a new desktop |
| Disconnected a long time | Yes — unless you opted in to `--reap-disconnected` |
| Log out from the desktop menu | No |
