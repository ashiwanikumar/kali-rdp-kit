#!/usr/bin/env bash
#
# Build kali-rdp-kit_<version>_all.deb into dist/.
#
set -euo pipefail

# Directory modes come from the build tree, so a builder with a permissive
# umask (002 is common on Debian/Kali, where users get a private group) would
# otherwise ship group-writable directories -- a lintian error. Pin it.
umask 022

# Reproducibility. Pinning the umask alone was never enough to make a local
# build match the published one: install(1) stamps every file with the current
# time, so two builds of identical source still differ, and anyone comparing
# their own build against the release asset sees a mismatch they cannot explain.
#
# Clamping mtimes to the last commit's date makes the .deb a function of the
# source alone. dpkg-deb reads SOURCE_DATE_EPOCH for the archive members; the
# files inside need touching directly.
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$(dirname "$0")/.." log -1 --pretty=%ct 2>/dev/null || date +%s)}
export SOURCE_DATE_EPOCH

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(awk -F'"' '/^KRK_VERSION=/{print $2}' "$ROOT/lib/common.sh")
[ -n "$VERSION" ] || { echo "cannot determine version from lib/common.sh" >&2; exit 1; }

PKG="kali-rdp-kit"
BUILD="$ROOT/build/${PKG}_${VERSION}"
DIST="$ROOT/dist"

echo "==> building $PKG $VERSION"
rm -rf "$BUILD"
mkdir -p "$BUILD/DEBIAN" \
         "$BUILD/usr/bin" \
         "$BUILD/usr/lib/$PKG" \
         "$BUILD/usr/share/$PKG" \
         "$BUILD/usr/share/doc/$PKG" \
         "$BUILD/usr/lib/systemd/system"

install -m 0755 "$ROOT"/bin/kali-rdp-setup   "$BUILD/usr/bin/"
install -m 0755 "$ROOT"/bin/kali-rdp-doctor  "$BUILD/usr/bin/"
install -m 0755 "$ROOT"/bin/kali-rdp-cleanup "$BUILD/usr/bin/"
install -m 0755 "$ROOT"/bin/kali-rdp-user    "$BUILD/usr/bin/"
install -m 0755 "$ROOT"/bin/kali-rdp-profile "$BUILD/usr/bin/"
install -m 0755 "$ROOT"/bin/kali-ssh-setup   "$BUILD/usr/bin/"
install -m 0644 "$ROOT"/lib/common.sh        "$BUILD/usr/lib/$PKG/"
install -m 0644 "$ROOT"/share/tmux/tmux.conf "$BUILD/usr/share/$PKG/"
install -d "$BUILD/usr/share/$PKG/profiles"
install -m 0644 "$ROOT"/share/profiles/*.profile "$BUILD/usr/share/$PKG/profiles/"
install -m 0644 "$ROOT"/share/systemd/kali-rdp-cleanup.service "$BUILD/usr/lib/systemd/system/"
install -m 0644 "$ROOT"/share/systemd/kali-rdp-cleanup.timer   "$BUILD/usr/lib/systemd/system/"
install -m 0644 "$ROOT"/README.md            "$BUILD/usr/share/doc/$PKG/"
install -m 0644 "$ROOT"/LICENSE              "$BUILD/usr/share/doc/$PKG/copyright"

# Version in control must track lib/common.sh, not drift from it.
sed "s/^Version: .*/Version: $VERSION/" "$ROOT/packaging/debian/control" \
    >"$BUILD/DEBIAN/control"

for f in postinst prerm postrm; do
    install -m 0755 "$ROOT/packaging/debian/$f" "$BUILD/DEBIAN/$f"
done

# Mark the tmux template as a conffile so local edits survive upgrades.
printf '/usr/share/%s/tmux.conf\n' "$PKG" >"$BUILD/DEBIAN/conffiles"

# Every path, including the DEBIAN control dir and the directories themselves.
find "$BUILD" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

mkdir -p "$DIST"
DEB="$DIST/${PKG}_${VERSION}_all.deb"
fakeroot dpkg-deb --build --root-owner-group "$BUILD" "$DEB" >/dev/null

echo "==> $DEB"
dpkg-deb --info "$DEB" | sed -n '1,12p'
if command -v lintian >/dev/null 2>&1; then
    echo "==> lintian"
    lintian "$DEB" || true
fi
