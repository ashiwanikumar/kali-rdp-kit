# shellcheck shell=bash
# i3 -- tiling, extremely light, no compositor to fight.

PROFILE_DESC="i3 tiling window manager. Minimal bandwidth (no animations or compositing) and no session-manager startup sequence to time out."
PROFILE_PACKAGES="i3 i3status dmenu xterm"
PROFILE_SESSION="i3"
PROFILE_STATUS="recommended"

profile_tweak() {
    local home=$1 user=$2
    # i3 prompts to generate a config on first run, which blocks a fresh RDP
    # session on a modal dialog the user cannot always reach.
    if [ ! -f "$home/.config/i3/config" ] && [ -f /etc/i3/config ]; then
        run install -d -o "$user" -g "$user" -m 0755 "$home/.config/i3"
        run install -o "$user" -g "$user" -m 0644 /etc/i3/config "$home/.config/i3/config"
    fi
}
