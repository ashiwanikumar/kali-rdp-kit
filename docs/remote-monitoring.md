# Running long jobs and checking them from your phone

The workflow this page is about: you start something long on the box — an AI
coding agent (Claude Code, Codex, Kimi), a scan, a build, a training run — then
close your laptop and want to check on it from a phone or tablet hours later.

**The short version: don't monitor a CLI job over RDP. Use SSH with `tmux`.**
RDP is for a desktop; it is a poor fit for watching a terminal from a 6-inch
screen, and it makes the job's survival depend on the desktop's survival. SSH +
`tmux` decouples the two.

---

## Start the job so it cannot die with your connection

```bash
tmux new -s work          # or: tmux new -A -s work  (attach if it exists)
claude                    # start the agent inside tmux
# Ctrl-b then d           # detach — the job keeps running
```

The `tmux` server is **not** an X client and is not a child of your shell. It
survives your SSH connection dropping, your RDP desktop ending, and your laptop
going to sleep. It does not survive a reboot.

`kali-ssh-setup` installs a snippet that attaches you to a `main` session
automatically on interactive SSH login, so reconnecting from any device puts you
straight back where you were. Set `KRK_NO_AUTOTMUX=1` to skip it for one login.

## Check on it from a phone

Any SSH client works — Termius, Blink, JuiceSSH, Termux. Two settings matter:

| Setting | Value | Why |
|---|---|---|
| Keepalive | 30s | Matches the server's `ClientAliveInterval`; stops NAT dropping an idle session |
| Terminal | `xterm-256color` | Colour output from AI CLIs renders correctly |

**Prefer `mosh` over plain SSH on mobile.** `kali-ssh-setup` installs it.

```bash
mosh you@your-box
```

Mosh is built for exactly this case: it survives IP changes (wifi → cellular),
tolerates high latency, and reconnects silently after the phone sleeps. A plain
SSH session dies on every network switch; a mosh session does not notice.

Mosh needs UDP ports 60000–61000 open in addition to SSH.

## What survives what

| | SSH drops | Desktop ends | Reboot |
|---|:---:|:---:|:---:|
| Job in `tmux` | **Yes** | **Yes** | No |
| Job in a plain SSH shell | No | n/a | No |
| Job in a desktop terminal | n/a | No | No |
| `nohup` / `setsid` job | **Yes** | **Yes** | No |
| GUI application | n/a | No | No |

The row that matters: **a job started in a desktop terminal dies with the
desktop.** The same command inside `tmux` does not, and you can reach it over
SSH without RDP at all.

To survive reboots too, run it as a systemd user service and enable lingering:

```bash
loginctl enable-linger "$USER"
```

---

## If you do want the desktop from a phone

Persistent desktops are the default, so disconnecting never closes your apps.
Two things still need attention for multi-device use.

### Screen locking — off

A lock screen inside RDP is a lockout risk, not a security gain: the RDP layer
already authenticated you, and the unlock dialog frequently cannot take keyboard
focus under Xvnc. Reconnect after a few hours and you can find yourself staring
at a prompt you cannot type into.

`kali-rdp-profile set <profile>` disables every known locker
(`xfce4-screensaver`, `light-locker`, `xscreensaver`, …) using a freedesktop
autostart override, so the locker never starts at all. `kali-rdp-doctor`
section 7 warns if one is running or would autostart.

### Colour depth — the reason you get two desktops

xrdp decides whether to give you an existing desktop or a new one using
`Policy` in `sesman.ini`. `Policy=Default` means `UB`: sessions are separated by
**user** and by **bits-per-pixel** — and per `sesman.ini(5)` the `B` criterion
**cannot be switched off**.

So if your phone's RDP client negotiates a different colour depth than your
laptop, you get a **second desktop**, and your work appears to have vanished
while it is in fact still running in the first one.

Two ways to handle it:

1. **Set the same colour depth in every client.** Zero server config, but you
   have to remember it on each device.
2. **Cap it server-side** so clients converge:

   ```bash
   sudo kali-rdp-setup --max-bpp 16
   ```

   Capping to 16 makes any client requesting 16 or more land on the same
   session. 16-bit colour is also markedly lighter over a mobile connection.
   A client requesting *less* than the cap still gets its own session, so pick
   the lowest depth you are willing to look at.

Check for accumulated desktops any time:

```bash
kali-rdp-doctor          # section 6 lists every session and whether it is attached
```

Several sessions for one user means the extras hold windows you thought you had
lost. Reconnect at the matching depth to get back into one.

---

## A sensible split

Use both, for what each is good at:

- **SSH + tmux (+ mosh)** — starting, watching, and steering long-running CLI
  work. This is what you want from a phone.
- **RDP** — when you genuinely need the GUI: a browser, a graphical tool,
  reading a rendered document.

The job lives in `tmux` either way, so it does not care which one you are using
at the time — including when you are using neither.
