#!/usr/bin/env bash
#
# kali-rdp-kit installer.
#
#   curl -fsSL https://raw.githubusercontent.com/ashiwanikumar/kali-rdp-kit/main/install.sh | sudo bash
#
# Installs the tools and the cleanup timer. It does NOT reconfigure xrdp --
# run `sudo kali-rdp-setup` for that, so the changes are yours to review.
#
set -euo pipefail

REPO="${KRK_REPO:-ashiwanikumar/kali-rdp-kit}"
REF="${KRK_REF:-main}"
PKG="kali-rdp-kit"
PREFIX="${PREFIX:-/usr}"

red=$'\033[31m'; grn=$'\033[32m'; blu=$'\033[34m'; rst=$'\033[0m'
info() { printf '%s==>%s %s\n' "$blu" "$rst" "$*"; }
die()  { printf '%sfatal:%s %s\n' "$red" "$rst" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (pipe to 'sudo bash', or run with sudo)"

if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
        *debian*|kali:*) ;;
        *) printf 'warning: %s is not Debian-based; continuing anyway\n' "${PRETTY_NAME:-unknown}" >&2 ;;
    esac
fi

for c in curl tar install systemctl; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
done

SRC=""
CLEANUP=""
if [ -f "$(dirname "$0")/lib/common.sh" ] && [ -d "$(dirname "$0")/bin" ]; then
    # Running from a checkout.
    SRC=$(cd "$(dirname "$0")" && pwd)
    info "installing from local checkout: $SRC"
else
    TMP=$(mktemp -d); CLEANUP=$TMP
    trap 'rm -rf "$CLEANUP"' EXIT
    info "downloading $REPO@$REF"
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" \
        | tar -xz -C "$TMP" --strip-components=1 \
        || die "download failed"
    SRC=$TMP
fi

info "installing files"
install -d "$PREFIX/bin" "$PREFIX/lib/$PKG" "$PREFIX/share/$PKG" /var/lib/$PKG/backups
install -m 0755 "$SRC"/bin/kali-rdp-setup   "$PREFIX/bin/"
install -m 0755 "$SRC"/bin/kali-rdp-doctor  "$PREFIX/bin/"
install -m 0755 "$SRC"/bin/kali-rdp-cleanup "$PREFIX/bin/"
install -m 0644 "$SRC"/lib/common.sh        "$PREFIX/lib/$PKG/"
install -m 0644 "$SRC"/share/tmux/tmux.conf "$PREFIX/share/$PKG/"
chmod 0750 /var/lib/$PKG

if [ -d /run/systemd/system ]; then
    install -m 0644 "$SRC"/share/systemd/kali-rdp-cleanup.service /etc/systemd/system/
    install -m 0644 "$SRC"/share/systemd/kali-rdp-cleanup.timer   /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now kali-rdp-cleanup.timer
    info "cleanup timer enabled"
else
    printf 'warning: systemd not detected; cleanup timer not installed\n' >&2
fi

cat <<EOF

${grn}kali-rdp-kit installed.${rst}

  sudo kali-rdp-setup --dry-run    review the xrdp changes
  sudo kali-rdp-setup              apply them
  kali-rdp-doctor                  diagnose the current state
  sudo kali-rdp-cleanup -n         preview orphan reaping

Nothing about your xrdp configuration has been changed yet.

EOF
