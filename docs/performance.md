# Performance: why you can't use Xvfb (with real measurements)

> 🌐 [中文](zh-CN/performance.md) ｜ **English**


## The short version

**For GPU gaming on a headless Linux box, never use `Xvfb` as the virtual display.**
It has no GPU acceleration path at all, so it locks you to an absurdly low framerate — and the
symptom is deeply misleading: GPU utilization is low, the CPU isn't busy either, yet the framerate
simply won't climb.

Use a **real Xorg running on the GPU** instead (that's what `20-setup-headless-xorg.sh` sets up).

## Measurements

Same machine (i7-11370H + RTX 3070 Laptop Max-Q), same virtual display resolution (2560×1664),
same benchmark (`glxgears`):

| Rendering path | Framerate |
|---|---|
| NVIDIA GPU → **Xvfb** | **15 fps** |
| Pure CPU software rendering (llvmpipe) | 85 fps |
| NVIDIA GPU → **real Xorg (headless)** | **4800 fps** (vsync off) |

Now the framerate-vs-resolution relationship (still plain `glxgears`):

| Window size | Framerate |
|---|---|
| 2560×1664 | 15 fps |
| 1280×832 | 54 fps |
| 960×624 | 60 fps |
| 800×600 | 122 fps |

**The framerate is strictly inversely proportional to the pixel count** — the signature of a pure
bandwidth bottleneck.

## Why

Xvfb is a pure-software X server. Once the GPU has rendered a frame, there's no way to hand the
result straight to it (Xvfb doesn't support DRI3, so there's no zero-copy buffer sharing). The only
option is:

```
GPU renders into its own offscreen buffer  →  the CPU copies the whole frame back  →  shoves it into Xvfb's buffer
```

At 2560×1664 one frame is `2560 × 1664 × 4 ≈ 17 MB`. That "copy it back" path measures about
**65 MPix/s** (≈256 MB/s) in practice, which gives you:

```
2560 × 1664 = 4.26 MPix  ÷  65 MPix/s  ≈  65 ms/frame  →  15 fps
```

Note that this number **has nothing to do with how demanding the game is**: turn off Minecraft's
shaders and the framerate is still 15fps (I measured it — identical). It's stuck on the copy, not on
the rendering.

## After switching to a real Xorg

Xorg + the NVIDIA driver work like this: applications render frames into **buffers in VRAM**, and
the X server composites and scans out from that same buffer. At no point is a frame copied through
the CPU.

The 17 MB/frame copy doesn't disappear — but it changes from "the render thread blocks and waits for
it" into "Sunshine grabs the screen asynchronously from another process", so it no longer stalls the
game's render loop.

## How to check whether you've walked into this trap

```bash
# 1. See what's actually running the virtual display
pgrep -af "Xorg :200"      # should be /usr/lib/xorg/Xorg, not Xvfb

# 2. Run glxgears (install mesa-utils)
DISPLAY=:200 __GL_SYNC_TO_VBLANK=0 glxgears
```

- **Thousands** of fps → you're fine, the GPU is rendering directly
- **Teens** of fps → you're bitten, and you're watching Xvfb's slow copy
- **Tens** of fps → you may be on llvmpipe software rendering; check `glxinfo | grep renderer`

## What 15fps actually feels like

Incidentally, this bottleneck also makes the **mouse and keyboard look broken**: 15fps video with a
cursor that barely moves, and you'll conclude the input path is at fault and go audit a pile of
unrelated things. Fix the framerate first, then debug input — doing it in the other order wastes a
lot of time.
