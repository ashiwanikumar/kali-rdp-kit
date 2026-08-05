# shellcheck shell=bash
# Openbox -- the reference profile for xrdp on Kali.

PROFILE_DESC="Openbox + tint2. Lightest, and the only profile with no known session-stability issues under Xvnc."
PROFILE_PACKAGES="openbox obconf tint2 xterm"
PROFILE_SESSION="openbox-session"
PROFILE_STATUS="recommended"

profile_tweak() {
    local home=$1 user=$2
    # A panel and a terminal, or the session is an empty grey screen and users
    # think it failed.
    local autostart="$home/.config/openbox/autostart"
    if [ ! -f "$autostart" ]; then
        run install -d -o "$user" -g "$user" -m 0755 "$home/.config/openbox"
        if [ "${KRK_DRY_RUN:-0}" != 1 ]; then
            cat >"$autostart" <<'EOF'
# Installed by kali-rdp-kit.
(sleep 1 && tint2) &
EOF
            chown "$user:$user" "$autostart"
        fi
    fi
}
