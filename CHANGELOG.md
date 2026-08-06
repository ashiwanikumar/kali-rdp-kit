# Changelog

## Unreleased

- Three scripts -- `kali-rdp-profile`, `kali-rdp-user`, `kali-ssh-setup` -- had
  shipped non-executable in git since the day they were added. The `.deb` was
  unaffected, because `build-deb.sh` installs with an explicit mode, so nothing
  ever caught it and only someone running from a checkout found out. Fixed, with
  a test that fails if any tracked script loses its mode again.
- `tools/reproduce-xfce-25s.sh`: a self-contained attempt to reproduce the Xfce
  ~25s session exit against a throwaway account, over a real RDP login, with
  `strace` and `dbus-monitor` attached before the failure window. Never touches
  the invoking user's session.
- `docs/xfce-25s.md` rewritten around two findings: 25 seconds is libdbus's
  default reply timeout, so the bug is a D-Bus call with no responder rather
  than a crash; and the fault does not reproduce on current packages under four
  distinct conditions. The Xfce profile is now `unreproduced` rather than a flat
  `known-issue`.
- `build-deb.sh` produces a byte-reproducible package. Pinning the umask was
  never enough on its own: `install(1)` stamps every file with the current
  time, so two builds of identical source differed and anyone comparing their
  own build against the release asset saw a mismatch they could not explain.
  Mtimes are now clamped to the last commit's date and `SOURCE_DATE_EPOCH` is
  exported for `dpkg-deb`. The v0.5.0 asset predates this, so a local build at
  that tag still differs from the published one in timestamps only -- its
  contents, modes and owners were verified identical.

## 0.5.0

Everything here came out of one live debugging session on a Kali VM under
vCenter, accessed from several devices — the failures are field reports, not
hypotheticals.

### Fixed

**`kali-rdp-doctor` reported resolved problems as current failures.** The
private-key check grepped the whole of `/var/log/xrdp.log`, which is never
truncated. One permission error, ever, meant a permanent `FAIL` — including
immediately after `kali-rdp-setup` fixed the permission and reported success.
Every log check is now scoped to the lifetime of the service that would be
producing the errors, handling both of xrdp's timestamp formats, wrapped
continuation lines, and logrotate moving the start of the window into the
previous file. Historical errors are reported as history, once, in passing.

The key check no longer relies on the log alone. It performs a live read as the
runtime user and cross-checks it against the scoped log, because the two
disagree in exactly the case that matters: `usermod -aG` takes effect for new
processes only, so between the fix and the restart the permissions look correct
while the running xrdp still cannot read anything.

**A restart orphaned every running desktop, silently.** `sesman` holds its
session table in memory, so restarting it forgets every desktop while the `Xvnc`
processes keep running — they are in a logind session scope, not the unit's
cgroup. The desktops stay alive with the user's work in them and no client can
rejoin; reconnecting builds a new empty one instead. `kali-rdp-setup` restarted
`xrdp-sesman` unconditionally on every run that changed anything. It now names
the desktops a restart would strand, asks first, declines when there is no
terminal to ask on, and offers `--no-restart` and `--yes`.

**`security_layer=negotiate` against a self-signed certificate.** Kali's
shipped default. Clients presented with a certificate they cannot validate
handle the negotiation inconsistently — the connection dies before a window
manager starts, giving a black screen and a drop, and the server logs only
`xrdp_sec_incoming failed`. `kali-rdp-setup` now pins `security_layer=tls`,
gated on the certificate and key being usable so a host without a working
certificate is never made worse. `--security-layer` overrides it.
`kali-rdp-doctor` warns about the combination.

**Benign log noise was reported as errors.** `g_tcp_bind ... errno=98` in
`xrdp-sesman.log` is how sesman probes for a free display; the following line is
always `Found X server running at ...`. Handshake failures from clients that
vanish mid-connect — a phone changing network, a port scanner — are
indistinguishable from a broken server in isolation, so they are now counted
against successful logins and only escalated when nothing is succeeding.

**A forking `Xvnc` was counted twice.** A server that daemonises is briefly
visible as both the launcher and the server it forked, which double-counted
desktops and could send the reaper after a pid that had already exited.

**`backup_file` aborted under `set -u`** when called without `krk_init_state`,
at the moment it was about to overwrite a file.

**The screen-locker check read the wrong home directory.** It looked in
`$HOME`, which is root's home the moment the doctor runs under sudo, so it
found no override and warned that a locker would start in a desktop where it
had been disabled long ago. It now resolves the invoking account (through
`SUDO_USER`) and the owners of running desktops, names which accounts it
checked, and says so rather than guessing when a home is unreadable.

**A key that could not be read was reported as a key that did not exist.**
`/etc/xrdp/key.pem` points into `/etc/ssl/private`, which is `0710`; `test -e`
follows the link, fails to traverse, and reports the key absent. Existence and
readability are now asked as separate questions, and "could not test" is a
distinct answer from "not readable" — conflating them made the tooling refuse
to apply its own fix.

### Added

- `kali-rdp-doctor` section 5: TLS and security layer — key readability,
  certificate presence, self-signed detection, expiry, security layer, and
  protocol versions.
- `kali-rdp-doctor` reports desktops `sesman` no longer tracks as `UNREACHABLE`,
  distinguishing a desktop that has simply been idle from one that cannot be
  reached at all. The test is the shape of the parentage
  (`Xvnc → xrdp-sesexec → xrdp-sesman`), not descent from sesman: everything a
  user runs inside their desktop is also a sesman descendant.
- Session churn detection: how many desktops have been created in the last
  hour, which separates "idle for a day, fine" from "sat through twenty
  reconnect attempts".
- Per-session colour depth and owner in the report and in `--json`, plus a
  warning when desktops exist at several depths — the reason a phone and a
  laptop reach different desktops.
- `kali-rdp-cleanup --orphans` and `--kill DISPLAY`, with a refusal to kill a
  desktop in use without `--yes`.
- `--json` gains `tls`, `log_window`, and per-session `owner`, `kind`, `depth`,
  `geometry` and `orphaned`.
- `KRK_XRDP_LOG` and `KRK_SESMAN_LOG` for non-standard log locations, and
  `KRK_XRDP_START_EPOCH` / `KRK_SESMAN_START_EPOCH` for hosts where systemd
  cannot report when a service started.
- Log-only failures are raised through `log_fail`, which downgrades to a warning
  when the window could not be dated to the running service. Without it the
  scoping fix had a hole: on a host with no way to establish a start time, the
  whole file becomes the window and an ancient error is asserted as current --
  the original bug by another route.
- `tests/run-tests.sh`: 49 regression tests, wired into CI. Every one of them
  exists because something above was reported as broken.

### Changed

- `kali-rdp-setup` verifies that xrdp is active and listening after a restart,
  and fails loudly rather than reporting success over a dead service.
- Deprecated TLS 1.0/1.1 are removed from `ssl_protocols` when present.
- Rejected login attempts are surfaced, with a note about port exposure.

## 0.4.1

- `kali-rdp-setup` warns before `--max-bpp` strands a running desktop.

## 0.4.0

- Lockout-proof profiles, multi-device sessions, remote-monitoring guide.

## 0.3.0

- Dev-tools provisioning, and honest Ubuntu guidance.

## 0.2.0

- SSH survival, user provisioning, desktop profiles, monitoring.

## 0.1.0

- Initial release.
