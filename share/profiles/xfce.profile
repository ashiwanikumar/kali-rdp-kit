# shellcheck shell=bash
# Xfce -- full desktop, but see the session-stability caveat below.

PROFILE_DESC="Xfce 4 full desktop. Feature-complete, but see docs/xfce-25s.md: xfwm4 has been observed exiting ~25s into a session under Xvnc."
PROFILE_PACKAGES="xfce4 xfce4-terminal"
PROFILE_SESSION="xfce4-session"
PROFILE_STATUS="known-issue"

profile_tweak() {
    local home=$1 user=$2

    # Compositing over a VNC transport is pure cost: every damage event becomes
    # a full recomposite that then has to be encoded and shipped.
    #
    # Applied to the live session first. Writing the XML is only correct when
    # no session is running -- otherwise xfconfd holds the settings in memory
    # and overwrites the file on logout, silently discarding the change.
    if krk_xfconf_set "$user" xfwm4 /general/use_compositing bool false; then
        ok "compositing disabled in the running session"
    else
        local xfwm="$home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
        if [ -f "$xfwm" ]; then
            # Rewriting this file wholesale would discard the user's theme,
            # keybindings and window rules, so leave it and say so plainly
            # rather than pretending the setting was applied.
            warn "compositing left as-is: $(basename "$xfwm") already exists and no session is running"
            warn "apply it from inside a session with:"
            warn "  xfconf-query -c xfwm4 -p /general/use_compositing -s false"
        elif [ "${KRK_DRY_RUN:-0}" != 1 ]; then
            install -d -o "$user" -g "$(id -gn "$user")" -m 0755 "$(dirname "$xfwm")"
            cat >"$xfwm" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Installed by kali-rdp-kit: compositing is a net loss over VNC. -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
            chown "$user:$(id -gn "$user")" "$xfwm"
            ok "compositing disabled for the next session"
        fi
    fi

    # Belt and braces alongside the autostart override applied to every
    # profile: if the locker is somehow started anyway, it still will not lock.
    krk_xfconf_set "$user" xfce4-screensaver /saver/enabled bool false || true
    krk_xfconf_set "$user" xfce4-screensaver /lock/enabled bool false || true
}
