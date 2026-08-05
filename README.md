# kali-rdp-kit

Reliable headless RDP and SSH on Kali Linux — setup, diagnostics, desktop
profiles, user provisioning, and orphan cleanup.

Kali ships `xrdp` but not `xorgxrdp`, the driver xrdp's default Xorg backend
needs. The result is a setup that looks installed, accepts your password, and
then hands you a black screen or a session that dies minutes later. Working
around that by hand means disabling the display manager, switching backends,
tuning `sesman.ini`, and periodically hunting down processes that outlived
their sessions.

This packages those fixes.

```bash
curl -fsSL https://raw.githubusercontent.com/ashiwanikumar/kali-rdp-kit/main/install.sh | sudo bash
sudo kali-rdp-setup --dry-run   # review
sudo kali-rdp-setup             # apply
kali-rdp-doctor                 # verify
```

Installing changes nothing about your xrdp configuration. `kali-rdp-setup` is a
separate, explicit step, and `--dry-run` prints every change first.

## The tools

| Command | What it does |
|---|---|
| `kali-rdp-setup` | Idempotent xrdp configuration |
| `kali-rdp-doctor` | Read-only diagnostics (`--json`, `--watch`) |
| `kali-rdp-cleanup` | Reaps orphaned session processes |
| `kali-rdp-profile` | Chooses and tunes the desktop a session starts |
| `kali-rdp-user` | Provisions users for RDP access |
| `kali-ssh-setup` | SSH keepalives, session persistence, hardening |

Every one of them takes `--dry-run`.


### `kali-rdp-setup` — idempotent configuration

Safe to re-run; every file it touches is backed up to
`/var/lib/kali-rdp-kit/backups/<timestamp>/` first.

| | |
|---|---|
| Display manager | Disables `lightdm`/`gdm3`/`sddm` and switches the default target to `multi-user`. A console session on `:0` shares the user's D-Bus session bus, `ICEauthority`, and agent sockets with RDP sessions; both fight over them. Keep it with `--keep-dm`. |
| Backend | Verifies the `[Xvnc]` session type and comments out `[Xorg]`, so the login dropdown cannot offer a backend that will hang. |
| Session policy | Sets `KillDisconnected=true` and `DisconnectedTimeLimit` in `sesman.ini` — correct for the day xorgxrdp lands, but **inert on Xvnc** (see below). |
| Cleanup | Enables the `kali-rdp-cleanup.timer`. |
| tmux | Installs a config that stops multi-client redraw corruption. Never overwrites an existing `~/.tmux.conf`. |

```
sudo kali-rdp-setup [-n|--dry-run] [--keep-dm] [--port PORT]
                    [--disconnect-limit SECONDS] [--no-tmux] [--no-timer]
```

### `kali-rdp-doctor` — read-only diagnostics

Runs the checks you would otherwise do by hand across eight areas — packages,
display-manager conflicts, services, backend config, disconnected-session
policy, live sessions, orphaned helpers, and recent log errors — and prints the
command that fixes each problem it finds.

Exit status: `0` clean, `1` warnings, `2` failures. Suitable for monitoring.

### `kali-rdp-cleanup` — orphan reaper

When an RDP client is closed without logging out, `Xvnc`, `xrdp-chansrv`, and
xrdp's pipewire module keep running. Reconnecting creates a *new* session
alongside the old one, and they contend for the same sockets.

**This reaps by disconnected-ness, not uptime.** xrdp proxies each client into
Xvnc's loopback port (`5900 + display`), so an ESTABLISHED connection there
means someone is actually looking at the session. A session with no client is
recorded on first sighting and killed only if still unattached after a grace
period (default 30 min).

That distinction matters. The obvious implementation — kill anything older than
N hours — kills the session you are working in the moment it crosses N hours.

```
sudo kali-rdp-cleanup [-n|--dry-run] [-g|--grace SECONDS] [-v|--verbose]
```

`--dry-run` is worth running first; it prints exactly what would die.

**Your apps stay open when you disconnect** — closing an RDP client is not a
logout. The desktop and everything in it keeps running, and reconnecting puts
you back in it. The grace period is how long a *disconnected* session is kept
before it is reaped; raise it if you want desktops to park for days:

```bash
sudo systemctl edit kali-rdp-cleanup.service   # Environment=KRK_GRACE_SECONDS=86400
```

See [docs/session-persistence.md](docs/session-persistence.md) for the full
picture, including why reconnecting sometimes hands you an empty desktop while
your windows are still running in another session.

### `kali-rdp-profile` — desktop profiles

Picks what an RDP session starts, and applies the workarounds that make that
desktop usable over a VNC transport (compositing off, screen locking off —
a lock screen inside RDP is a lockout risk, not a security gain).

```bash
kali-rdp-profile list                    # openbox, i3, xfce, kde
sudo kali-rdp-profile set openbox
sudo kali-rdp-profile set xfce --user alice
kali-rdp-profile show
```

`openbox` and `i3` are marked recommended: neither runs a session manager with
a startup sequence that can time out. `xfce` is marked known-issue — see below.

### `kali-rdp-user` — provisioning

```bash
sudo kali-rdp-user add alice --profile openbox
sudo kali-rdp-user add bob --profile xfce --sudo --ssh-key ~/bob.pub
kali-rdp-user list
```

Creates the account, adds it to the terminal-server group *if* your `sesman.ini`
actually enforces one (it reads `AlwaysGroupCheck` and `TerminalServerUsers`
rather than assuming), installs the tmux config, and applies a desktop profile.

### `kali-ssh-setup` — connection survival

```bash
sudo kali-ssh-setup                # keepalives, mosh, tmux auto-attach, fail2ban
sudo kali-ssh-setup --harden       # + disable password auth and root login
```

Writes a drop-in to `/etc/ssh/sshd_config.d/` and never edits `sshd_config`.
Validates with `sshd -t` before the config can take effect, and **reloads rather
than restarts**, so the session you are running it from is not dropped.

`--harden` is refused unless an authorized key already exists for you or root —
the check exists specifically to stop you locking yourself out of a remote box.

The tmux auto-attach snippet is guarded on `$-` containing `i` and on
`SSH_CONNECTION` being set, so `scp`, `rsync`, `sftp`, and `ssh host cmd` are
unaffected. Set `KRK_NO_AUTOTMUX=1` to bypass it for one login.

### Monitoring

```bash
kali-rdp-doctor --watch        # live refreshing view
kali-rdp-doctor --watch 30     # every 30s
kali-rdp-doctor --json         # machine-readable
```

`--json` emits a session inventory alongside the checks:

```json
{
  "status": "warn",
  "counts": {"pass": 14, "warn": 3, "fail": 0},
  "sessions": [
    {"display": 18, "pid": 2503788, "connected": true,
     "cpu_percent": 4.8, "uptime_seconds": 3475}
  ],
  "checks": [ ... ]
}
```

Exit status is `0`/`1`/`2`, so it drops straight into a monitoring check.

## What it fixes, and why

**1. Console and RDP sessions collide.** A display manager running a session on
`:0` shares per-user resources with RDP sessions. Symptoms are non-obvious:
sessions that start then immediately exit, D-Bus errors, a dead keyring.

**2. `xorgxrdp` is not in Kali's repos.** Confirmed by `apt-cache policy
xorgxrdp` returning `Candidate: (none)`. Without it the Xorg backend attempts
to touch real graphics hardware. The Xvnc backend needs no such driver.

**3. Session processes outlive their sessions, and sesman will not stop it.**
This is the one that surprises people. `sesman.ini(5)` states that
`KillDisconnected` and `DisconnectedTimeLimit` *"currently only work with
xorgxrdp sessions"*. Kali has no xorgxrdp, so on every Kali box those keys are
accepted, look correct in the config, and do nothing.

The practical consequence: on an Xvnc backend **nothing in xrdp reaps
disconnected sessions**. That job falls entirely to `kali-rdp-cleanup`. A
config that reads as properly tuned will still accumulate sessions forever.

Helpers that reparent to init are not covered by any xrdp mechanism either —
notably xrdp's pipewire module. On the machine this was built for, 21 had
accumulated over six days.

**4. Multiple tmux clients on one session.** tmux resizes the window to the
smallest attached client on every attach. Over RDP that reads as redraw
corruption. `window-size manual` stops the renegotiation.

## Known issue: Xfce sessions exiting after ~25 seconds

Not fixed, and not yet root-caused. `xfwm4` exits a consistent ~25 seconds after
session start under Xvnc + RDP, across clean rebuilds. The consistency points at
a timeout on a D-Bus or polkit call during Xfce's startup sequence rather than a
crash, but that is a hypothesis, not a diagnosis.

**Openbox is a workaround, not a fix.** If you hit this:

```bash
echo "openbox-session" > ~/.xsession
```

See [docs/xfce-25s.md](docs/xfce-25s.md) for how to capture a usable trace if
you want to help pin it down.

## Building the .deb

```bash
./packaging/build-deb.sh          # -> dist/kali-rdp-kit_0.1.0_all.deb
sudo dpkg -i dist/kali-rdp-kit_*.deb
```

`dpkg-deb` and `fakeroot` are required; `lintian` is used if present.

## Uninstalling

```bash
sudo systemctl disable --now kali-rdp-cleanup.timer
sudo rm -f /usr/bin/kali-rdp-{setup,doctor,cleanup}
sudo rm -rf /usr/lib/kali-rdp-kit /usr/share/kali-rdp-kit
sudo rm -f /etc/systemd/system/kali-rdp-cleanup.{service,timer}
```

Configuration changes are not reverted automatically — restore from
`/var/lib/kali-rdp-kit/backups/`, which is preserved until you purge the
package.

## Scope

Kali Rolling, `xrdp` 0.10.x, Xvnc backend. It should work on Debian-based
systems generally, but that is untested. Contributions welcome — especially a
real diagnosis of the Xfce issue above.

MIT licensed.
