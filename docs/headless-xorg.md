# Headless Xorg: running the X server directly on the GPU

> 🌐 [中文](zh-CN/headless-xorg.md) ｜ **English**

Scripts: `scripts/20-setup-headless-xorg.sh` + `scripts/make-edid.py`

## The big picture

To run games on a machine with **no physical monitor**, you have to fool three things:

1. **The GPU driver** — make it believe a monitor is plugged into one of its outputs → `ConnectedMonitor`
2. **The X server** — give it a usable framebuffer for that fake monitor → **an EDID is mandatory**
3. **Applications** — show them a sane resolution and DPI → the timing + physical size in the EDID

Item 2 is the one that bites hardest; details below.

## Trap 1: with no EDID, the framebuffer can't be read back

If all you set is `AllowEmptyInitialConfiguration` + `ConnectedMonitor`, Xorg starts fine, `xrandr`
reports 2560×1664, and `glxinfo` recognizes the GPU — **but every screen capture comes out pure
black**:

```bash
DISPLAY=:200 xsetroot -solid red          # paint the root window solid red
DISPLAY=:200 import -window root /tmp/a.png
convert /tmp/a.png -format '%[pixel:p{100,100}]' info:
#   → gray(0)     ← black. xwd and ffmpeg -f x11grab do the same thing
```

What Sunshine captures is black too, so the stream you send out is a **black screen**.

The reason: a "ghost output" with no EDID has no real scanout path in the NVIDIA driver, and the
driver makes no promise that the front buffer can be read back.

**The fix**: hand it a real EDID file (`make-edid.py` is what generates one).

```apache
Option "CustomEDID" "DFP-0:/home/you/game-stream-edid.bin"
```

Add that and the exact same command immediately captures `srgb(255,0,0)`.

> By the way: you *can* use an off-the-shelf EDID (say the 128 bytes dumped from some other
> monitor), but then your resolution is pinned to whatever that EDID describes. Generating your own
> is the only way to get the resolution you actually want.

## Trap 2: DPI is determined by the EDID's physical size

Besides the timing, an EDID also carries the monitor's **physical size in millimeters**. The X server
uses it to compute DPI:

```
DPI = resolution / (physical size / 25.4)
```

Fill in the wrong size (say 344×194mm copied from a laptop panel's EDID) and at 2560×1664 you get
**191 DPI** — so programs like Chromium/CEF (**and nearly every game launcher is CEF**) scale their
UI 2×, the buttons land off-screen, and you can't even click "Start Game".

`make-edid.py` works backwards: give it a target DPI (96 by default) and it derives the physical
size.

```bash
python3 scripts/make-edid.py --from-config scripts/config.env
#   timing       : 2560x1664 @ 59.97 Hz (pixel clock 362.25 MHz)
#   physical size: 680x440 mm  →  DPI 96x96
```

Verify:

```bash
DISPLAY=:200 xdpyinfo | grep -E "dimensions|resolution"
#   dimensions:    2560x1664 pixels (680x440 millimeters)
#   resolution:    96x96 dots per inch
```

## Trap 3: nvidia_drv.so isn't on the default module path

Ubuntu's NVIDIA package installs it at
`/usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so`, which is not under Xorg's default search path
of `/usr/lib/xorg/modules/drivers/`. So the config has to add the ModulePath explicitly:

```apache
Section "Files"
    ModulePath "/usr/lib/x86_64-linux-gnu/nvidia/xorg"
    ModulePath "/usr/lib/xorg/modules"
EndSection
```

Otherwise you get `Failed to load module "nvidia"`.

## Output connectors (the names used by ConnectedMonitor / CustomEDID)

On a headless box you have to invent a name. Find out which connectors your GPU has:

```bash
ls /sys/class/drm/         # e.g. card1-HDMI-A-1, card1-DP-1, card1-eDP-1
```

The NVIDIA driver usually calls them `DFP-0`, `DFP-1` (digital outputs), `HDMI-0`, `DP-0`, and so
on. **A laptop's discrete GPU normally has no directly wired output, and `DFP-0` is usually enough
to fool it** (that's the default value too).

Whether custom timings are accepted also depends on:

```apache
Option "ModeValidation" "AllowNonEdidModes, NoEdidModes, NoMaxPClkCheck, \
       NoVertRefreshCheck, NoHorizSyncCheck, NoDFPNativeResolutionCheck, \
       NoVirtualSizeCheck, AllowInterlacedModes"
```

Without that list, the driver rejects your resolution on the grounds that "the EDID has no such
mode".

## About `-ac` (disabling access control)

The service starts Xorg with `-ac`: that turns off X's access control so ordinary users on the same
machine (Sunshine, xdotool, your game) can connect to this display.

Fine on a single-user box. On a shared machine, generate an Xauthority file and distribute the
cookie to whoever needs it.

## Why a systemd service instead of nohup

```bash
systemctl status gamestream-xorg
sudo systemctl restart gamestream-xorg        # passwordless sudo is already configured
```

The benefits:
- Automatic restart when it crashes (`Restart=always`)
- Starts on boot
- Logs in one place: `/var/log/gamestream-xorg.log`
- The display number lives in `~/gamestream-xorg.env`, and changing it doesn't need root

## Changing resolution / moving to another machine

```bash
# 1. Edit STREAM_WIDTH / STREAM_HEIGHT / STREAM_DPI / XORG_OUTPUT in config.env
# 2. Regenerate the EDID
python3 scripts/make-edid.py --from-config scripts/config.env
# 3. Regenerate the Xorg config and restart
sudo bash scripts/20-setup-headless-xorg.sh
```

One recommendation: **make the stream resolution match the Mac's native resolution**, so the client
never has to scale and you get the sharpest image:

| Machine | Native resolution |
|---|---|
| MacBook Air 13" | 2560×1664 |
| MacBook Pro 14" | 3024×1964 |
| MacBook Pro 16" | 3456×2234 |
| External 2K monitor | 2560×1440 |
