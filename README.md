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
| `kali-ssh-setup` | SSH keepalives, mosh, tmux auto-attach, hardening |

Every one of them takes `--dry-run`.


### `kali-rdp-setup` — idempotent configuration

Safe to re-run; every file it touches is backed up to
`/var/lib/kali-rdp-kit/backups/<timestamp>/` first.

| | |
|---|---|
| Display manager | Disables `lightdm`/`gdm3`/`sddm` and switches the default target to `multi-user`. A console session on `:0` shares the user's D-Bus session bus, `ICEauthority`, and agent sockets with RDP sessions; both fight over them. Keep it with `--keep-dm`. |
| Backend | Verifies the `[Xvnc]` session type and comments out `[Xorg]`, so the login dropdown cannot offer a backend that will hang. |
| Session policy | Sets `KillDisconnected=false`: disconnecting never closes your apps. Inert on Xvnc anyway, but set explicitly so behaviour cannot change the day xorgxrdp appears. |
| Security layer | Pins `security_layer=tls`. Kali ships `negotiate` plus a self-signed certificate, and letting clients choose against a certificate they cannot validate produces intermittent handshake failures — a black screen and a drop before any window manager starts. Only applied once the key is confirmed readable, so a host without a usable certificate is never made worse. Override with `--security-layer`. |
| Cleanup | Enables the `kali-rdp-cleanup.timer`. |
| tmux | Installs a config that stops multi-client redraw corruption. Never overwrites an existing `~/.tmux.conf`. |

```
sudo kali-rdp-setup [-n|--dry-run] [--keep-dm] [--port PORT] [--max-bpp N]
                    [--security-layer tls|negotiate|rdp]
                    [--reap-disconnected SECONDS] [--no-tmux] [--no-timer]
                    [--no-restart] [-y|--yes]
```

**Restarting orphans running desktops.** `xrdp-sesman` keeps its session table
in memory, so restarting it forgets every desktop while the `Xvnc` processes
carry on running. Those desktops keep your applications alive but no client can
rejoin them — reconnecting builds a new empty one instead. Setup lists exactly
which desktops a restart would strand and asks before doing it; with no
terminal to ask on it declines and tells you how to proceed. `--no-restart`
writes the configuration without applying it; `--yes` skips the prompt.

### `kali-rdp-doctor` — read-only diagnostics

Runs the checks you would otherwise do by hand across ten areas — packages,
display-manager conflicts, services, backend config, TLS and security layer,
disconnected-session policy, live sessions, screen lockers, orphaned helpers,
and recent log errors — and prints the command that fixes each problem it finds.

Exit status: `0` clean, `1` warnings, `2` failures. Suitable for monitoring.

Two things it deliberately does *not* do:

- **It never reports history as news.** Every log check is scoped to the
  lifetime of the process that would be producing the errors, so a permission
  problem you fixed last week stops being reported the moment it is fixed. A
  tool that keeps failing on a resolved issue teaches you to ignore its
  failures.
- **It grades noise as noise.** xrdp logs routine events at `ERROR` level.
  `g_tcp_bind ... errno=98` in `xrdp-sesman.log` is how sesman *probes* for a
  free display — the next line is always `Found X server running at ...`.
  Handshake errors from a client that vanished mid-connect (a phone changing
  network, a port scanner) look identical to a broken server, so they are
  counted against successful logins rather than reported on their own.

### `kali-rdp-cleanup` — orphan reaper

When an RDP client is closed without logging out, `Xvnc`, `xrdp-chansrv`, and
xrdp's pipewire module keep running. Reconnecting creates a *new* session
alongside the old one, and they contend for the same sockets.

**Desktops are never closed. Only dead helpers are reaped.** Closing an RDP
client is a disconnect, not a logout: your applications keep running, and
reconnecting returns you to the same windows, days later if you like.

What *is* reaped by default is unambiguous garbage — a `xrdp-chansrv` or
pipewire module whose X server is already gone. Those hold sockets and leak
memory for as long as the box stays up.

There is one further class, reported but never reaped without asking: a desktop
`sesman` no longer tracks. Its session table lives only in memory, so a sesman
restart or crash leaves the `Xvnc` running with no path back to it — the
applications are alive, and unreachable. `--orphans` clears them; `--kill
DISPLAY` takes down one specific desktop, refusing a desktop currently in use
unless you pass `--yes`.

```
sudo kali-rdp-cleanup [-n|--dry-run] [-g|--grace SECONDS|never] [-v|--verbose]
                      [--orphans] [--kill DISPLAY] [-y|--yes]
```

On a shared box you may want idle desktops reclaimed. That is opt-in, because
it closes users' applications:

```bash
sudo kali-rdp-setup --reap-disconnected 86400   # close after a day disconnected
```

Even then the decision keys on whether a client is attached, never on uptime.
The obvious implementation — kill anything older than N hours — kills the
session you are working in the moment it crosses N hours.

See [docs/session-persistence.md](docs/session-persistence.md) for the full
picture, including why reconnecting sometimes hands you an empty desktop while
your windows are still running in another session.

Running long jobs — AI agents, scans, builds — and checking them from a phone or
tablet? See [docs/remote-monitoring.md](docs/remote-monitoring.md). Short version:
run the job in `tmux` and reach it over SSH/mosh rather than RDP, so the job's
survival does not depend on the desktop's.

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

Every profile also **disables screen lockers** (`xfce4-screensaver`,
`light-locker`, `xscreensaver`, …) via a freedesktop autostart override. A lock
screen inside RDP is a lockout risk rather than a security gain: the RDP layer
already authenticated, and the unlock dialog often cannot take keyboard focus
under Xvnc — so you reconnect after hours away and cannot type into the prompt.

### `kali-rdp-user` — provisioning

```bash
sudo kali-rdp-user add alice --profile openbox
sudo kali-rdp-user add bob --profile xfce --sudo --ssh-key ~/bob.pub
sudo kali-rdp-user add alice --with-dev-tools        # node + Claude Code
kali-rdp-user list
```

Creates the account, adds it to the terminal-server group *if* your `sesman.ini`
actually enforces one (it reads `AlwaysGroupCheck` and `TerminalServerUsers`
rather than assuming), installs the tmux config, and applies a desktop profile.

`--with-dev-tools` additionally installs **node system-wide** (`/usr/bin/node`,
from the distro archive) plus `git`, `ripgrep`, and `build-essential`, then
installs **Claude Code** for that user and puts `~/.local/bin` on their `PATH`.

Node goes system-wide deliberately: an `nvm` install lives in one user's home
and is invisible to every account created afterwards — which is how a new user
ends up with a working desktop and no runtime. Claude Code goes per-user just as
deliberately: it self-updates in place under `~/.local/share/claude`, so a single
shared copy would either fail to update or let one user's upgrade silently change
everyone else's version.

Node is **not** a Claude Code prerequisite — the native install is a
self-contained binary. It's here for ordinary development work, so a failed node
install is a warning, never a blocker.

The flag is idempotent — re-run it on an existing user to add the toolchain
without touching anything else.

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

## Does this work on Ubuntu?

**Mostly — and the tools adapt automatically — but it is untested there, and one
premise genuinely differs.**

Everything is gated on capability rather than distro: `kali-rdp-doctor` and
`kali-rdp-setup` branch on whether `xorgxrdp` is installed, not on which distro
is running. So the behaviour changes on its own where it should.

| | Kali | Ubuntu (24.04 / 22.04) |
|---|---|---|
| `xorgxrdp` in the archive | **No** | **Yes** (universe) |
| Working backend | Xvnc only | Xorg *or* Xvnc |
| `KillDisconnected` honoured? | No — inert | **Yes** |
| Default display manager | none / lightdm | gdm3 (handled) |
| `nodejs` in archive | 24.x | 18.x (24.04), 12.x (22.04) |

The consequence: **on Ubuntu the Xorg backend actually works**, so `setup` leaves
it enabled and you may prefer it — it generally outperforms Xvnc. And because
sesman honours `KillDisconnected` there, `setup` writing `KillDisconnected=false`
is what preserves persistent desktops rather than being a no-op.

Untested and likely to need attention on Ubuntu:

- The whole toolkit is **unverified on Ubuntu** — it is developed and tested on
  Kali Rolling only. Treat it as "should work", not "known to work".
- `--with-dev-tools` installs the archive's node: **18 on 24.04, 12 on 22.04**.
  Both are older than recommended; the tool warns and points at NodeSource.
- The `xfce` profile's ~25s issue was only ever observed under Xvnc. On Ubuntu's
  Xorg backend it may not reproduce at all.

Reports from Ubuntu users are very welcome — that is the fastest way to turn
"should work" into "does work".

## Scope

Developed and tested on Kali Rolling with `xrdp` 0.10.x and the Xvnc backend.
Debian and Ubuntu should work (see above) but are untested. Contributions
welcome — especially a real diagnosis of the Xfce issue above.

MIT licensed.
