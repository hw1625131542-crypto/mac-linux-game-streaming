# Architecture

> 🌐 [中文](zh-CN/architecture.md) ｜ **English**


## Data flow

```
┌─ Linux host (no monitor attached) ─────────────────────────────────────────────────────┐
│                                                                                        │
│  ┌─ Xorg :200 (systemd: gamestream-xorg, runs as root) ─────────────────────────────┐  │
│  │   · runs straight on the NVIDIA GPU                                              │  │
│  │   · ConnectedMonitor makes the driver believe a monitor is attached              │  │
│  │   · CustomEDID provides the timing and DPI (without it, no framebuffer readback) │  │
│  │              ↑                                                                   │  │
│  │   the game renders into a VRAM buffer, zero CPU copies                           │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
│         ↑ keyboard/mouse events                  ↓ video frames                        │
│  ┌─ Sunshine (user service, runs as an unprivileged user) ──────────────────────────┐  │
│  │   capture : capture = x11 (XCB screen grab)                                      │  │
│  │   encode  : encoder = nvenc (H.264/HEVC hardware encoding)                       │  │
│  │   input   : write to /dev/uinput → the kernel creates a virtual                  │  │
│  │             mouse/keyboard → Xorg claims it via udev hotplug                     │  │
│  └──────────────────────────────────────────────────────────────────────────────────┘  │
│         ↑ input stream (UDP)                     ↓ video/audio stream (UDP)            │
└────────────────────────────────────────────────────────────────────────────────────────┘
                                     ↕ LAN
┌─ Mac ──────────────────────────────────────────────────────────────────────────────────┐
│  Moonlight (--absolute-mouse --vsync)                                                  │
│    · decode video → display                                                            │
│    · capture mouse/keyboard/gamepad → send back                                        │
│    · AWDL guard: off while streaming, restored afterwards (keeps AirDrop)              │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

## Ports

| Port | Purpose |
|---|---|
| 47989/tcp | Service discovery (HTTP) |
| 47984/tcp | Pairing handshake (HTTPS) |
| 47990/tcp | Web admin UI |
| 48010/tcp + 47998-48010/udp | Video / audio / control streams |

If the host runs ufw, remember to allow them (same LAN):

```bash
sudo ufw allow from 192.168.0.0/16 to any port 47984,47989,47990,48010 proto tcp
sudo ufw allow from 192.168.0.0/16 to any port 47998:48010 proto udp
sudo ufw reload
```

## Why "the whole desktop" instead of "a single app"

Moonlight's two streaming modes:

| Mode | How it works | Pros | Cons |
|---|---|---|---|
| **Desktop (this approach)** | Streams an entire virtual desktop | Any game runs, no per-game config to write; you can drive launchers and in-game menus | Needs a window manager; resolution is fixed |
| Application | Launches one program and streams its window | Lighter on resources | Every game has to be configured in Sunshine's `apps.json`; launcher-style UIs are actually harder to drive |

This project picks Desktop because **a lot of games require their official launcher to complete
the login**, so you need to see and click through that launcher inside the stream.

## Component lifecycle

| Component | Started by | What happens when it dies |
|---|---|---|
| `gamestream-xorg` | systemd (system-level, `Restart=always`) | Restarts automatically; the stream drops, just reconnect |
| Sunshine | systemd user service (`Restart=on-failure`) | Restarts automatically |
| openbox | `50-session-up.sh` makes sure it's running | Game windows never get focus and input stops working |
| Game | launched by `50-session-up.sh` | Restart it by hand, or re-run the script |

`50-session-up.sh` is **idempotent**: the Mac side calls it on every double-click, and calling it
again won't spawn a second game instance or reset your session.

## Key design tradeoffs

**Why does the display number live in its own file (`~/gamestream-xorg.env`)?**
Changing the display number shouldn't mean editing a root-owned systemd unit — edit a user file and
restart the service:

```bash
echo 'GS_DISPLAY=:201' > ~/gamestream-xorg.env
sudo -n systemctl restart gamestream-xorg
```

**Why does Xorg run with `-ac`?**
It turns off X's access control, so ordinary users on the same machine (Sunshine, xdotool) can
connect to it. That's fine on a single-user box; on a shared machine, hand out Xauthority cookies
instead.

**Why should the host scripts tolerate sudo failing?**
`50-session-up.sh` uses `sudo -n` (non-interactive). If the passwordless rules aren't set up, it
prints a hint instead of hanging on a password prompt — because the Mac side calls it over SSH,
non-interactively.
