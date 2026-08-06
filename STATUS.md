# Project status and handoff notes

**Read this first if you are picking the work up cold** — a new session, a new
contributor, or yourself in three months. `README.md` says what the tools do;
this file says where the work stands, what is known to be true, what is only
believed, and what a change must not break.

Last updated: 2026-08-06, just after v0.5.0 was released.

---

## Where things stand

| | |
|---|---|
| Version | 0.5.0 (`KRK_VERSION` in `lib/common.sh` is the single source of truth) |
| Released | tag `v0.5.0`, GitHub release published with the .deb attached |
| Branch | `main`; the work branch was merged fast-forward and deleted |
| Tests | `./tests/run-tests.sh` — 58 checks, all passing, no root or xrdp needed |
| Lint | shellcheck clean at `--severity=warning` across every script |
| Package | `./packaging/build-deb.sh` → `dist/kali-rdp-kit_0.5.0_all.deb`, byte-reproducible |
| Installed | 0.5.0 is installed on this host and its binaries match the tag |

`main` has moved past the tag: the build-reproducibility fix landed after
v0.5.0 was cut, so it belongs to the next release.

Nothing is half-finished. The open items below are all "would be nice", not
"left broken".

## What v0.5.0 was about

One real incident: an RDP session dropped and then would not reconnect. Four
faults came out of debugging it, and the pattern behind three of them is worth
holding onto — **the tooling was confidently wrong**, which is worse than being
silent, because it sends you chasing the wrong thing for hours.

See `CHANGELOG.md` for the itemised list. The short version:

1. The doctor grepped whole log files, so a fixed problem stayed "broken"
   forever. Now every log check is scoped to the current service lifetime.
2. `kali-rdp-setup` restarted `xrdp-sesman` on every run, which orphans every
   running desktop. The tool being used to fix a session was stranding it.
3. `security_layer=negotiate` against Kali's self-signed certificate causes
   intermittent handshake failures. Now pinned to `tls`.
4. Benign log noise was reported as errors, and vice versa.

## Design rules that must not be broken

These are the load-bearing decisions. Breaking one reintroduces a bug that
someone already lost an evening to.

**Never report history as news.** Any new check that reads a log must go
through `krk_log_since` or one of the doctor's pre-built windows
(`$XRDP_WINDOW`, `$SESMAN_WINDOW`). A bare `grep /var/log/xrdp.log` is the
v0.4.1 bug, rewritten.

**Undated evidence cannot justify a failure.** When the service start time
cannot be established the window is the whole file, so a hard `FAIL` from it is
the same false alarm by another route. Raise log-only failures through
`log_fail`, which downgrades to a warning and says why it is uncertain. CI
caught this one: the runner has no xrdp to date against, and the first cut of
the fix failed there for exactly the reason it was written to prevent.

**"Could not test" is not "failed".** `krk_can_read_as` returns 0/1/2 and the
three must stay distinct. Collapsing 2 into 1 is what made setup refuse to
apply its own fix.

**Existence and readability are separate questions.** `/etc/xrdp/key.pem`
points into `/etc/ssl/private` (mode 0710), so `test -e` reports the key absent
to anyone outside `ssl-cert`. Use `krk_path_present` for existence and
`krk_can_read_as` for readability.

**A desktop is only an orphan if its *parentage shape* is broken**, not merely
if it descends from something. The tracked shape is
`Xvnc → xrdp-sesexec → xrdp-sesman`. Everything a user runs inside their
desktop is also a sesman descendant, so a descent test calls every
hand-started X server "tracked" and finds nothing.

**Standalone `Xvnc` is never ours.** A server started with `vncserver(1)` (no
`sesman_passwd` in its argv) must never be counted, warned about, or reaped.

**Desktops persist by default.** Disconnecting is not logging out. Only
`--grace`, `--orphans` and `--kill` may end a desktop, and `--kill` refuses one
in use without `--yes`.

**Never make RDP worse than you found it.** Config changes that could lock
someone out — pinning `tls` above all — are gated on verifying the
preconditions first, and downgrade to advice when they cannot be verified.

**xrdp logs routine events at ERROR level.** Before treating a new signature as
a fault, check what the surrounding lines say. `g_tcp_bind ... errno=98` is
display probing, always followed by `Found X server running at ...`.

## Verified against a live system

Done on a Kali VM under vCenter, xrdp 0.10.6.1, Xvnc backend, single user:

- Log scoping cut a real `xrdp.log` from 37804 lines to 59, and 46 historical
  `Cannot read private key` hits to 0.
- Orphan detection: started a throwaway `Xvnc :59` faked to look sesman-managed,
  confirmed the doctor reports it `UNREACHABLE` and the live `:22` as tracked,
  then reaped it with `--orphans` and confirmed port 5959 was released.
- `--kill :22` on the attached session refused without `--yes`, both
  interactively and non-interactively.
- The churn detector reported 14 desktops created in the last hour, matching the
  incident's actual reconnect storm in `xrdp-sesman.log`.
- `negotiate` + snakeoil detection, and the `negotiate → tls` upgrade, exercised
  against a sandbox copy of `/etc/xrdp` under `unshare -r`.

Confirmed as real root after installing 0.5.0: `krk_can_read_as` returns 0 via
the `runuser` path against `/etc/xrdp/key.pem`, so `sudo kali-rdp-doctor`
reports "xrdp can read the TLS key" from an actual read rather than an
inference. `sudo kali-rdp-setup --dry-run` reports 0 changes and skips the
restart, which is the correct answer on an already-configured host and means the
restart guard is not tripped needlessly.

## Not verified, and why

**The restart-orphans-desktops behaviour is inferred, not reproduced.** It
follows from three observed facts — sesman's session table is in-memory, `Xvnc`
lives in a `session-N.scope` rather than the unit's cgroup, and
`xrdp-sesman.service` is `BindsTo=xrdp.service` — but deliberately was not
tested by restarting xrdp, because doing so would have destroyed the user's live
session. Reproduce on a scratch host if you want certainty.

**Nothing has been tested on Ubuntu**, or against xrdp older than 0.10. The
legacy `[20260806-04:59:53]` log format is handled and unit-tested, but no real
old-xrdp host has been seen.

## Open items

Small, none blocking:

- `MaxSessions=50` on this host draws a warning. It is Kali's default; consider
  whether the doctor's threshold of 20 is the right one.
- `auth_fail` counts `login failed|Access denied` in `xrdp.log` only; sesman
  logs some rejections too, so the count can be low.
- Depth `?` (an `Xvnc` with no `-depth` in argv) would be treated as a distinct
  colour depth by the multi-depth warning. Not reachable via sesman, which
  always passes `-depth`.
- The doctor's `--watch` re-execs itself; each iteration builds fresh log
  windows. Fine at a 5s interval on this host, but it is O(log size) per tick.
- The v0.5.0 release asset predates the reproducibility fix, so rebuilding at
  that tag gives a different checksum (timestamps only; contents were verified
  identical). Re-pointing the tag would refresh it — the release workflow is
  idempotent — but nothing is wrong with the published package.
- The Xfce ~25s session exit is still not root-caused, but it is no longer
  unfalsifiable: `tools/reproduce-xfce-25s.sh` tries it against a throwaway
  account over a real RDP login, and it did not reproduce under four conditions
  on current packages. The leading untested hypothesis is a console
  display-manager session competing with the RDP session for the user bus --
  which `kali-rdp-setup` already prevents by disabling the display manager, and
  which would explain why it no longer occurs. Testing it needs a scratch host,
  because the collision under test would take out a live desktop.

## Working on it

```bash
./tests/run-tests.sh            # 51 checks; add one for every bug you fix
shellcheck --severity=warning bin/* lib/common.sh tests/run-tests.sh
./packaging/build-deb.sh        # dist/kali-rdp-kit_<version>_all.deb
sudo dpkg -i dist/kali-rdp-kit_*_all.deb
```

Testing without root or a live xrdp:

- Point `KRK_XRDP_DIR` at a copy of `/etc/xrdp` to exercise config paths.
- `KRK_XRDP_LOG` / `KRK_SESMAN_LOG` redirect the log checks at fixtures.
- `KRK_XRDP_START_EPOCH` / `KRK_SESMAN_START_EPOCH` pin the service start time,
  which makes log scoping deterministic regardless of whether the machine has a
  live xrdp. They also cover the real case of a host where systemd cannot answer.
- A `systemctl` stub that exits 1, early on `PATH`, is how the suite reproduces
  a container or sysvinit host and exercises the undated-log path.
- `unshare -r` gives a fake root for the `require_root` paths. Beware: inside
  it, `runuser` and `ps -o user=` do not behave like real root, so
  `krk_can_read_as` returns 2 and process owners read as `root`.
- A fake `ps` on `PATH` is how `tests/run-tests.sh` exercises the inventory
  parser — see the `FAKE_PS` fixtures.

Releasing: bump `KRK_VERSION` in `lib/common.sh` (everything else derives from
it), add a `CHANGELOG.md` entry, build, tag.

## This host, for context

Kali under vCenter, single user `ashvani`, xrdp on port 41980 with
`security_layer=tls` and `max_bpp=16` already applied by hand during the
incident. `/var/log/xrdp*.log` are `0640 root:adm`, so the doctor needs `adm`
membership or root to read them. No `xorgxrdp` — Kali does not ship it, which is
why the Xvnc backend and everything downstream of it exists.
