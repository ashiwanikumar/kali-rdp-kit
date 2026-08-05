# Contributing

## Ground rules for these scripts

This tool runs as root, edits system config, and kills processes. Three rules
follow from that, and patches that break them will not be merged:

1. **Every mutating action goes through `run`.** That is what makes `--dry-run`
   trustworthy. If `--dry-run` ever changes something, that is a serious bug.
2. **Back up before editing.** Use `backup_file` before any write under `/etc`.
3. **Never kill on uptime.** Reaping decisions must be based on whether a
   session is actually in use. Killing a session someone is working in is the
   worst thing this tool can do, and it is exactly what the naive
   implementation does.

For anything touching sshd, add the fourth rule: validate with `sshd -t` before
the config can take effect, and `reload` rather than `restart`.

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
shellcheck --severity=warning bin/* lib/common.sh install.sh packaging/build-deb.sh
for f in bin/* lib/common.sh; do bash -n "$f"; done
```

CI runs both, plus a package build and a smoke test.

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
