# shellcheck shell=bash
# KDE Plasma -- heaviest option; workable with effects off.

PROFILE_DESC="KDE Plasma (X11). Heavy over RDP; usable once desktop effects and compositing are disabled."
PROFILE_PACKAGES="kde-plasma-desktop"
PROFILE_SESSION="startplasma-x11"
PROFILE_STATUS="heavy"

profile_tweak() {
    local home=$1 user=$2
    # KWin compositing over VNC is the single biggest source of lag in a Plasma
    # RDP session; without this the desktop is technically working but unusable.
    local kwinrc="$home/.config/kwinrc"
    if [ ! -f "$kwinrc" ] && [ "${KRK_DRY_RUN:-0}" != 1 ]; then
        cat >"$kwinrc" <<'EOF'
# Installed by kali-rdp-kit: compositing is unusably slow over VNC.
[Compositing]
Enabled=false
EOF
        chown "$user:$user" "$kwinrc"
    fi
}
