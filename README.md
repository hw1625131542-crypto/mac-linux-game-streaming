# Headless Linux → Mac Game Streaming

> 🌐 **English** ｜ [中文](README.zh-CN.md)

> Stream games running on a **headless Linux box with an NVIDIA GPU** to a Mac at **1440p / 60fps**.
> Sunshine (host) + Moonlight (Mac), with every trap documented and scripts you configure — not edit.

---

## What this repo is for

Most Sunshine/Moonlight guides assume a **Windows host with a monitor attached**. The moment you
switch to a **headless Linux + NVIDIA** box, you walk into a series of traps — and every one of them
presents misleading symptoms:

| What you see | What's actually wrong | Details |
|---|---|---|
| 1440p streaming runs at **15fps**, and a better GPU or lower settings don't help | `Xvfb` has no GPU acceleration path, so every frame is copied back through the CPU | [performance.md](docs/performance.md) |
| Screenshots and the stream are **pure black**, but the X server looks perfectly healthy | A headless NVIDIA output with **no EDID** has no readable framebuffer | [headless-xorg.md](docs/headless-xorg.md) |
| The game launcher's UI is **scaled 2×** and the buttons are off-screen | The EDID's physical size produced **191 DPI** instead of 96 | [headless-xorg.md](docs/headless-xorg.md) |
| **Mouse and keyboard do nothing at all** in the stream | `/dev/uinput` permissions, plus Xvfb's inability to hotplug input devices | [input.md](docs/input.md) |
| The cursor **vanishes and gets stuck** the moment you click into the window | Moonlight defaults to relative mouse + pointer capture; desktop streaming needs absolute | [macos-client.md](docs/macos-client.md) |
| **Brief stutters every few seconds**, yet packet loss looks low | macOS **AWDL** (the AirDrop radio) periodically hijacks the Wi-Fi radio | [network.md](docs/network.md) |
| The game is **hard-locked to exactly 30fps** while the GPU sits at 47% | Exclusive fullscreen on a headless display | [game-tuning.md](docs/game-tuning.md) |

---

## Architecture

```
┌─ Linux host (no monitor attached) ────────────────────┐
│                                                       │
│  Xorg :200  ← runs directly on the NVIDIA GPU         │
│    · custom EDID provides 2560x1664@60 + 96 DPI       │
│         ↑ the game renders into VRAM, zero copy       │
│  Sunshine                                             │
│    · capture = x11 (XCB) + NVENC encoding             │
│    · creates virtual mouse/keyboard via uinput,       │
│      which Xorg claims through udev hotplug           │
└───────────────────────────────────────────────────────┘
                  ↓ LAN / Tailscale
┌─ Mac ─────────────────────────────────────────────────┐
│  Moonlight (--absolute-mouse --vsync)                 │
│  AWDL guard: off while streaming, restored after      │
└───────────────────────────────────────────────────────┘
```

---

## Quick start

### 0. Requirements

- **Host**: Ubuntu/Debian with an NVIDIA GPU (official driver installed) and working SSH
- **Client**: a Mac with [Moonlight](https://moonlight-stream.org/)
- Both machines on the same LAN (or both on Tailscale)

### 1. Clone & configure

```bash
git clone https://github.com/<you>/mac-linux-game-streaming.git
cd mac-linux-game-streaming

cp scripts/config.env.example scripts/config.env
$EDITOR scripts/config.env      # ★ the only file you need to edit: IPs, user, resolution
```

Every value in `config.env` is commented, and every script reads from it —
**you never edit the scripts themselves**.

### 2. Host: one-time setup

Copy the repo to the host (or clone it there directly), then:

```bash
cd ~/mac-linux-game-streaming

# 1. install dependencies (X11 tools, cvt, xdotool, openbox, ...)
bash scripts/10-install-deps.sh

# 2. generate a custom EDID (resolution / refresh / DPI come from config.env)
python3 scripts/make-edid.py --from-config scripts/config.env

# 3. install the headless Xorg service + passwordless sudo rule
sudo bash scripts/20-setup-headless-xorg.sh

# 4. fix /dev/uinput permissions (or Sunshine can't create virtual input devices)
sudo bash scripts/30-fix-input-permissions.sh
```

### 3. Host: Sunshine and the game

```bash
bash scripts/40-configure-sunshine.sh    # writes sunshine.conf (capture=x11 and friends)
bash scripts/50-session-up.sh            # brings up Xorg + Sunshine + the launcher (idempotent)
```

### 4. Mac side

```bash
cp scripts/mac/start-stream.command ~/Stream-Games.command
chmod +x ~/Stream-Games.command
$EDITOR ~/Stream-Games.command      # host name / SSH address (or point it at config.env)
```

Double-click it.

**To keep AirDrop working when you're not streaming** (recommended):

```bash
sudo bash scripts/mac/install-awdl-guard.sh
```

It installs a daemon that disables AWDL while Moonlight is streaming and restores it afterwards.

---

## Repository layout

```
.
├── README.md                  # English (default)
├── README.zh-CN.md            # Chinese
├── docs/
│   ├── *.md                   # English docs
│   └── zh-CN/*.md             # Chinese docs
├── scripts/
│   ├── config.env.example     # ★ every configurable value (copy to config.env)
│   ├── lib.sh                 # shared helpers (config loading, logging, checks)
│   ├── 10-install-deps.sh
│   ├── make-edid.py           # generate a custom EDID (any resolution / DPI)
│   ├── 20-setup-headless-xorg.sh
│   ├── 30-fix-input-permissions.sh
│   ├── 40-configure-sunshine.sh
│   ├── 50-session-up.sh
│   └── mac/
│       ├── start-stream.command   # one-click launch from the Mac
│       ├── awdl-guard.sh          # toggles AWDL off only while streaming
│       ├── install-awdl-guard.sh
│       └── set-audio.swift        # switch the Mac's default audio output
└── LICENSE
```

---

## Measured results (reference baseline)

On a laptop with an **i7-11370H (4c/8t) + RTX 3070 Laptop Max-Q**, at 2560×1664:

| Configuration | Framerate | GPU utilization |
|---|---|---|
| `Xvfb` virtual display (what most guides tell you to do) | **15 fps** | 28% (the GPU is waiting on the CPU copy) |
| Pure software rendering (llvmpipe) | 85 fps | — |
| **This repo: headless Xorg on the GPU** | **60 fps** | 40–58% |

Same machine, same resolution, same benchmark (`glxgears`) — which proves the bottleneck was the
display server, not the GPU.

---

## License

MIT — use it however you like; issues and PRs welcome.
