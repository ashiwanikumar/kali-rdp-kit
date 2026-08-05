# shellcheck shell=bash
# Xfce -- full desktop, but see the session-stability caveat below.

PROFILE_DESC="Xfce 4 full desktop. Feature-complete, but see docs/xfce-25s.md: xfwm4 has been observed exiting ~25s into a session under Xvnc."
PROFILE_PACKAGES="xfce4 xfce4-terminal"
PROFILE_SESSION="xfce4-session"
PROFILE_STATUS="known-issue"

profile_tweak() {
    local home=$1 user=$2

    # Compositing over a VNC transport is pure cost: every damage event becomes
    # a full recomposite that then has to be encoded and shipped. Off is both
    # faster and one less thing interacting with the session-start sequence.
    local xfwm="$home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    if [ ! -f "$xfwm" ]; then
        run install -d -o "$user" -g "$user" -m 0755 "$(dirname "$xfwm")"
        if [ "${KRK_DRY_RUN:-0}" != 1 ]; then
            cat >"$xfwm" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Installed by kali-rdp-kit: compositing is a net loss over VNC. -->
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF
            chown "$user:$user" "$xfwm"
        fi
    fi

    # A screen lock inside an RDP session is a lockout risk, not a security
    # gain: the RDP layer already authenticated, and the unlock dialog often
    # cannot get keyboard focus under Xvnc.
    local saver="$home/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-screensaver.xml"
    if [ ! -f "$saver" ]; then
        run install -d -o "$user" -g "$user" -m 0755 "$(dirname "$saver")"
        if [ "${KRK_DRY_RUN:-0}" != 1 ]; then
            cat >"$saver" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Installed by kali-rdp-kit: screen locking inside RDP is a lockout risk. -->
<channel name="xfce4-screensaver" version="1.0">
  <property name="saver" type="empty">
    <property name="enabled" type="bool" value="false"/>
  </property>
  <property name="lock" type="empty">
    <property name="enabled" type="bool" value="false"/>
  </property>
</channel>
EOF
            chown "$user:$user" "$saver"
        fi
    fi
}
