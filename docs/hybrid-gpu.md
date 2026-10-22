# Hybrid GPU: when the same machine also runs a desktop

> 🌐 [中文](zh-CN/hybrid-gpu.md) ｜ **English**

Everything in this repo assumes a **headless** box: no monitor, no desktop, a dedicated X server
on `:200` for streaming. That works perfectly — until the machine is a **laptop you also use
normally**, with one discrete GPU and a desktop session you actually want.

This document is about that case, because it fails in a way that is easy to misdiagnose.

---

## The problem: one GPU, one DRM master

Linux's DRM subsystem allows **exactly one "master"** per graphics card at a time. The master is
whoever opened the device and took control of modesetting — normally the desktop's X server.

So when your desktop session (GNOME via PRIME, for example) is running and holds the NVIDIA card:

```
mc-xorg  →  (EE) NVIDIA(GPU-0): Failed to acquire modesetting permission.
            (EE) NVIDIA(0): Failing initialization of X screen
            (EE) no screens found
```

…and the streaming X server exits. `Restart=always` makes it retry forever, so you get a service
that flaps in `activating` and a `:200` that never exists.

The reverse order fails too, and this is the part that confuses people: if `mc-xorg` starts
**first** and takes the GPU, then the **desktop** fails instead — gdm starts, tries to bring up
its X server, and exits. What you see is a **blank console with a blinking cursor**, and:

```bash
$ systemctl is-active graphical.target
inactive
$ ls /tmp/.X11-unix/
X200                        # only the streaming display exists
```

**Ordering does not fix this.** With a single GPU there is no schedule in which both can own it.
It is a mutual exclusion, not a race.

---

## Confirming the diagnosis

```bash
# 1. Which mode are we in?
systemctl is-active gdm          # desktop
systemctl is-active mc-xorg      # streaming display

# 2. Who actually has the GPU?
journalctl -b | grep -iE "gdm-x-session.*nvidia" | tail -3
#   Loading nvidia_drv.so / libglxserver_nvidia.so  → the desktop has it

# 3. The smoking gun
grep -a "modesetting permission" /var/log/mc-xorg.log | tail -3

# 4. Which VT is on screen? (a blank console = the greeter never took over)
cat /sys/class/tty/tty0/active
```

---

## The pattern: mutually exclusive modes

Two scripts, each takes the machine to one state. No daemon decides for you — the mode is
whatever you last asked for, and the streaming one is triggered by the Mac's one-click script.

### `mode-streaming.sh`

```bash
systemctl stop gdm          # release the GPU
systemctl start mc-xorg     # start the headless X server
systemctl --user start sunshine
```

### `mode-desktop.sh`

```bash
systemctl --user stop sunshine
systemctl stop mc-xorg
systemctl start gdm
```

Both need root for the `systemctl` calls, so add a **narrow** sudoers rule instead of running the
scripts as root:

```sudoers
you ALL=(root) NOPASSWD: /usr/bin/systemctl start mc-*, /usr/bin/systemctl stop mc-*, \
                          /usr/bin/systemctl start gdm, /usr/bin/systemctl stop gdm
```

And **disable auto-start** for the streaming service, so a cold boot lands on the desktop:

```bash
sudo systemctl disable mc-xorg
```

With that, the daily loop becomes:

| You do | The machine does |
|---|---|
| Boot | Desktop, login screen |
| Double-click the Mac's launch script | Stops gdm → starts `mc-xorg` + Sunshine → starts the game |
| Close Moonlight | (optional, see below) closes the game → returns to the desktop |

---

## Two traps inside this pattern

### 1. The second X server steals the virtual terminal

Starting `mc-xorg` while the greeter is up made the **screen go blank** even after the GPU issue
was gone: X allocates a VT for itself and **switches to it**, so the greeter is still running on
`tty1` but you are looking at `tty2`.

Add `-novtswitch` (and do **not** add `-sharevts` — it does not help and can fail the modeset):

```ini
ExecStart=/usr/lib/xorg/Xorg ${GS_DISPLAY} -config ... -noreset -nolisten tcp -ac -novtswitch
```

Verify with `cat /sys/class/tty/tty0/active` — it should stay on the greeter's VT.

### 2. Sunshine is tied to the graphical session

The packaged Sunshine user service has:

```ini
[Install]
WantedBy=graphical-session.target
```

If the greeter fails, `graphical-session.target` never activates — so **Sunshine never starts**,
and you get a working X server with nothing listening. This is why "the desktop is broken" also
silently means "streaming is broken".

Decouple it:

```ini
# ~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-independent-of-desktop.conf
[Install]
WantedBy=default.target
```

Then `systemctl --user daemon-reload && systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`.

---

## Optional: return to the desktop automatically

If you only stream when you are going to play, a small watcher makes the switch back automatic:
detect the Sunshine client disconnecting, close the game cleanly, then run `mode-desktop.sh`.

Guard rails worth copying:

- **A 30-second grace period** — a brief network hiccup should not kill the session.
- **Close the game with a window-close message**, not `kill -9`, so it saves.
- **Only act if `mc-xorg` is active**, so a stale daemon cannot yank the desktop out from under you.
- **Count connections, don't parse timestamps**: `CLIENT CONNECTED` minus `CLIENT DISCONNECTED`
  from `~/.config/sunshine/sunshine.log`.

See `scripts/60-mode-switch.sh` for the pair of mode scripts and `scripts/61-auto-return.sh` for
the watcher.

---

## When both really must run at once

Only possible if the desktop **never touches the discrete GPU**. On a hybrid laptop the internal
panel and USB-C/DisplayPort outputs are usually wired to the **integrated** GPU, so a desktop on
`i915`/`amdgpu` can coexist with a headless X server on the NVIDIA card:

```xorg
# /etc/X11/xorg.conf.d/10-igpu-only.conf
Section "Device"
    Identifier "igpu"
    Driver     "modesetting"
    BusID      "PCI:0:2:0"
EndSection
```

The cost is real: with no NVIDIA driver in the desktop's X server, **PRIME offload for local games
is gone** — a game launched locally will run on the integrated GPU. If you play anything demanding
on that machine, this is not the trade you want.

| Layout | Desktop | Streaming | Local gaming on dGPU |
|---|---|---|---|
| Desktop only | ✅ | ❌ | ✅ |
| Streaming only | ❌ | ✅ | ❌ |
| Mutually exclusive (this doc) | ✅ | ✅ (one at a time) | ✅ |
| Desktop on iGPU | ✅ | ✅ **simultaneous** | ❌ |

---

## Checklist

```
[ ] sudo systemctl disable mc-xorg           # boot lands on the desktop
[ ] sudoers rule for starting/stopping gdm
[ ] -novtswitch in the mc-xorg ExecStart
[ ] Sunshine service: WantedBy=default.target
[ ] mode-streaming.sh / mode-desktop.sh tested in both directions
[ ] verify: ls /tmp/.X11-unix/ shows X0 in desktop mode, X200 in streaming mode
[ ] verify: cat /sys/class/tty/tty0/active stays on tty1 in desktop mode
```
