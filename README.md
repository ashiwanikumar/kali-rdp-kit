# kali-rdp-kit

Reliable headless RDP on Kali Linux — setup, diagnostics, and orphan cleanup.

Kali ships `xrdp` but not `xorgxrdp`, the driver xrdp's default Xorg backend
needs. The result is a setup that looks installed, accepts your password, and
then hands you a black screen or a session that dies minutes later. Working
around that by hand means disabling the display manager, switching backends,
tuning `sesman.ini`, and periodically hunting down processes that outlived
their sessions.

This packages those fixes.

```bash
curl -fsSL https://raw.githubusercontent.com/ashvani/kali-rdp-kit/main/install.sh | sudo bash
sudo kali-rdp-setup --dry-run   # review
sudo kali-rdp-setup             # apply
kali-rdp-doctor                 # verify
```

Installing changes nothing about your xrdp configuration. `kali-rdp-setup` is a
separate, explicit step, and `--dry-run` prints every change first.

## The three tools

### `kali-rdp-setup` — idempotent configuration

Safe to re-run; every file it touches is backed up to
`/var/lib/kali-rdp-kit/backups/<timestamp>/` first.

| | |
|---|---|
| Display manager | Disables `lightdm`/`gdm3`/`sddm` and switches the default target to `multi-user`. A console session on `:0` shares the user's D-Bus session bus, `ICEauthority`, and agent sockets with RDP sessions; both fight over them. Keep it with `--keep-dm`. |
| Backend | Verifies the `[Xvnc]` session type and comments out `[Xorg]`, so the login dropdown cannot offer a backend that will hang. |
| Session policy | Sets `KillDisconnected=true` and `DisconnectedTimeLimit` in `sesman.ini`. |
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

## What it fixes, and why

**1. Console and RDP sessions collide.** A display manager running a session on
`:0` shares per-user resources with RDP sessions. Symptoms are non-obvious:
sessions that start then immediately exit, D-Bus errors, a dead keyring.

**2. `xorgxrdp` is not in Kali's repos.** Confirmed by `apt-cache policy
xorgxrdp` returning `Candidate: (none)`. Without it the Xorg backend attempts
to touch real graphics hardware. The Xvnc backend needs no such driver.

**3. Session processes outlive their sessions.** `KillDisconnected` handles the
clean case. It does not cover helpers that reparent to init — notably xrdp's
pipewire module, which lingers indefinitely. On the machine this was built for,
21 of them had accumulated over six days.

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
