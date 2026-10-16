# Troubleshooting quick reference

> 🌐 [中文](zh-CN/troubleshooting.md) ｜ **English**

Look up what you're seeing. Every entry comes with a command to tell you what's actually wrong.

---

## Can't connect / pairing

| Symptom | Check |
|---|---|
| Host doesn't show up in Moonlight | Is Sunshine running on the server: `pgrep -x sunshine`; does the web UI load: `https://<IP>:47990` |
| Pairing fails | Firewall ports (see [architecture.md](architecture.md#ports)); a stale Moonlight instance is running: `pkill -x Moonlight` |
| Error `Found unexpected PC "X" looking for "Y"` | Host names don't match. `sunshine_name` in the server's `sunshine.conf` must match the entry in Moonlight |
| Connects, then immediately drops | Check `~/.config/sunshine/sunshine.log` on the server; the usual cause is `capture = x11` never being set |

---

## Video

| Symptom | Cause / fix |
|---|---|
| **All black, but the X server is healthy** | EDID isn't taking effect. See [headless-xorg.md](headless-xorg.md). Verify: `DISPLAY=:200 xsetroot -solid red; import -window root /tmp/a.png; convert /tmp/a.png -format '%[pixel:p{10,10}]' info:` should print red |
| **Frame rate locked at 15fps** | The virtual display fell back to Xvfb. `pgrep -af "Xorg :200"` should show `/usr/lib/xorg/Xorg`; see [performance.md](performance.md) |
| **Frame rate locked at exactly 30fps** | The game is in exclusive fullscreen. See [game-tuning.md](game-tuning.md#1-frame-rate-locked-at-exactly-30fps). Telltale signs: the GPU is only at 40–60%, and the frame rate doesn't change when you stop streaming |
| **Horizontal tearing** | Moonlight is missing `--vsync` |
| **Blurry / blocky image** | The adaptive bitrate has throttled it down. Check AWDL ([network.md](network.md)) and your bitrate settings |
| **Screenshots come out pure black** | Same as the "all black" row — EDID |
| Picture freezes, log repeats `Waiting for IDR frame` | Serious packet loss on the link. Check AWDL / lower the bitrate |
| The stream window is smaller than the image, with black bars | The stream resolution's aspect ratio doesn't match the Moonlight window. Set `STREAM_WIDTH/HEIGHT` to the Mac's native screen resolution |

---

## Input

| Symptom | Cause / fix |
|---|---|
| **Mouse and keyboard do nothing at all** | ① `grep -c libvirtualhid /proc/bus/input/devices` should be around 5; if it's 0 → `sudo bash scripts/30-fix-input-permissions.sh`; ② then `sudo -n systemctl restart gamestream-xorg` so Xorg hotplugs them again; ③ confirm openbox is running (no WM means no focus) |
| **Cursor vanishes the moment you click into the window and won't come out** | Moonlight is missing `--absolute-mouse`. Emergency workaround: `Ctrl+Alt+Shift+M` |
| Keyboard/mouse only fails inside certain programs | Most likely that program uses XInput2 raw mode. Try `--no-game-optimization`, or inject through uinput (see [input.md](input.md#a-handy-trick-use-uinput-key-injection-for-automation)) |
| Gamepad doesn't respond | Gamepads go through uhid, a separate path from the mouse/keyboard's uinput. Check the permissions on `/dev/uhid`; the game itself also needs controller support (SDL) |

---

## Audio

| Symptom | Fix |
|---|---|
| Video but no sound | ① Server-side chain: with the game running, `pactl list sink-inputs \| grep -A2 "Sink Input"` should show the game's audio pointed at `sink-sunshine-stereo`; ② Mac default output device: run `~/bin/set-audio` and see whether it has switched over to a display |
| Audio cuts in and out | Audio packets are being lost in groups. Look for `Unable to recover audio data block` in the Moonlight log. Same treatment as video stutter (AWDL / lower the bitrate) |

---

## Server-side components

```bash
# Display server
systemctl status gamestream-xorg
sudo systemctl restart gamestream-xorg        # passwordless sudo is already configured
tail -40 /var/log/gamestream-xorg.log

# Streaming service
systemctl --user status sunshine
systemctl --user restart sunshine
tail -40 ~/.config/sunshine/sunshine.log

# Window manager (without it, keyboard and mouse never reach the game)
pgrep -x openbox || (setsid openbox &)

# One-shot bring-up (idempotent)
bash scripts/50-session-up.sh
```

---

## Quick health-check script

```bash
DISP=:200

echo "== X server =="; pgrep -af "Xorg $DISP" || echo "  x not running"
echo "== resolution / DPI =="; DISPLAY=$DISP xdpyinfo | grep -E "dimensions|resolution"
echo "== renderer =="; DISPLAY=$DISP glxinfo 2>/dev/null | grep "OpenGL renderer"
echo "== framebuffer =="; DISPLAY=$DISP xsetroot -solid red; sleep 1
                    DISPLAY=$DISP import -window root /tmp/_t.png 2>/dev/null && \
                    convert /tmp/_t.png -format '  %[pixel:p{10,10}]\n' info:
                    DISPLAY=$DISP xsetroot -solid black
echo "== virtual input devices (kernel) =="; grep -c libvirtualhid /proc/bus/input/devices
echo "== virtual input devices (Xorg) =="; DISPLAY=$DISP xinput list 2>/dev/null | grep -c libvirtualhid
echo "== window manager =="; pgrep -x openbox >/dev/null && echo "  ✓" || echo "  ✗"
echo "== Sunshine =="; pgrep -x sunshine >/dev/null && echo "  ✓" || echo "  ✗"
echo "== GPU =="; nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv,noheader
```

On a healthy machine the output should look like:

```
== X server ==                      12345 /usr/lib/xorg/Xorg :200 -config ...
== resolution / DPI ==              dimensions: 2560x1664 pixels (680x440 millimeters)
                                    resolution: 96x96 dots per inch
== renderer ==                      OpenGL renderer string: NVIDIA GeForce RTX 3070 Laptop GPU/PCIe/SSE2
== framebuffer ==                   srgb(255,0,0)          <- red means the EDID is working
== virtual input devices ==         5
== virtual input devices (Xorg) ==  4
== window manager ==                ✓
== Sunshine ==                      ✓
```

Three things are worth checking in that output:

- **`OpenGL renderer` is your actual GPU**, not `llvmpipe` — otherwise you're on software rendering
- **`srgb(255,0,0)`** — the framebuffer is readable, which means the EDID is doing its job
- **`5` virtual input devices in the kernel and `4` claimed by Xorg** — the mismatch is normal
  (one of them, the touchscreen, is not something Xorg picks up as a slave device)
