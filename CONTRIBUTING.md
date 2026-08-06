# Contributing

## Ground rules for these scripts

This tool runs as root, edits system config, and kills processes. These rules
follow from that, and patches that break them will not be merged:

1. **Every mutating action goes through `run`.** That is what makes `--dry-run`
   trustworthy. If `--dry-run` ever changes something, that is a serious bug.
2. **Back up before editing.** Use `backup_file` before any write under `/etc`.
3. **Never kill on uptime.** Reaping decisions must be based on whether a
   session is actually in use. Killing a session someone is working in is the
   worst thing this tool can do, and it is exactly what the naive
   implementation does.
4. **Never report history as news.** Any check that reads a log goes through
   `krk_log_since`, or one of the doctor's pre-built windows. A bare grep over
   `/var/log/xrdp.log` reports problems that were fixed weeks ago as if they
   were happening now, and a tool that cries wolf gets ignored when it is right.
5. **"Could not test" is not "failed".** Where a probe can be inconclusive, say
   so and fall back — see `krk_can_read_as`, which returns three distinct
   answers for exactly this reason. Collapsing them made the tool refuse to
   apply its own fix.

For anything touching sshd, add: validate with `sshd -t` before the config can
take effect, and `reload` rather than `restart`.

[`STATUS.md`](STATUS.md) carries the rest of the load-bearing design decisions,
plus what is verified against a live system and what is only inferred. Read it
before changing session or log handling.

## Development

```bash
git clone https://github.com/ashiwanikumar/kali-rdp-kit
cd kali-rdp-kit

# Run from the checkout without installing:
KRK_LIB=./lib KRK_SHARE=./share bash bin/kali-rdp-doctor

# Build and install:
./packaging/build-deb.sh
sudo dpkg -i dist/kali-rdp-kit_*.deb
```

Before opening a PR:

```bash
./tests/run-tests.sh
shellcheck --severity=warning bin/* lib/common.sh tests/run-tests.sh \
    install.sh packaging/build-deb.sh
for f in bin/* lib/common.sh; do bash -n "$f"; done
```

CI runs all three, plus a package build and a smoke test.

`tests/run-tests.sh` needs neither root nor a working xrdp: it drives the
helpers with log fixtures, a fake `ps` on `PATH`, and overridden lineage
functions. **Add a case for every bug you fix** — every check in there exists
because something was once reported as broken.

## Versioning

`KRK_VERSION` in `lib/common.sh` is the single source of truth. `build-deb.sh`
reads it, and the release workflow refuses to publish if the git tag disagrees.

## Testing a change safely

Test on a box you can reach out-of-band. `kali-ssh-setup --harden` and anything
touching the display manager can cut off your only way in. Every tool has
`--dry-run`; use it first.

## Especially wanted

A real diagnosis of the Xfce ~25s session exit — see
[docs/xfce-25s.md](docs/xfce-25s.md), which describes how to capture a usable
trace. Right now the project ships a workaround, not a fix, and it is the
biggest open gap.
