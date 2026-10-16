# In-game tuning: when the hardware has headroom but the frame rate won't move
> 🌐 [中文](zh-CN/game-tuning.md) ｜ **English**

Once the streaming link is fixed, the frame rate often still sticks at some strange value. This
section is the order to work through.

## 1. Frame rate locked at exactly 30fps

### Symptoms

- The frame rate is exactly 30 — not 28, not 33, exactly 30
- GPU utilization is only **40–60%**, clearly nowhere near saturated
- Stop streaming entirely (`systemctl --user stop sunshine`) and measure again: **the frame rate
  doesn't move at all**

That last point is the key one: it proves the bottleneck is neither the stream nor the hardware.

### Cause: exclusive fullscreen

On a headless virtual display, the exclusive-fullscreen presentation path locks itself to 30fps.
(In principle it wants to take over the display mode and vsync, but the timing semantics of a
virtual output are not the same as a real monitor's.)

### Fix

Switch the game's display mode to **windowed**:

- Minecraft + Sodium: Options → Video Settings → Fullscreen Mode, change `Exclusive` to `Off`
- Other games: look for an option along the lines of Windowed / Borderless

Measured with everything else identical: exclusive fullscreen **30fps** → windowed **45fps**, and
stacking the fixes in the sections below takes you to 60.

**Companion tweak**: windowed mode brings a title bar, which looks wrong. Have the window manager
drop the game window's decorations instead:

```xml
<!-- ~/.config/openbox/rc.xml, inside <applications> -->
<application class="Minecraft*">
  <decor>no</decor>
  <maximized>true</maximized>
  <position force="yes"><x>0</x><y>0</y></position>
</application>
```

`50-session-up.sh` adds this rule automatically. The result: it looks exactly like fullscreen, but
it takes the windowed path.

> **Don't press F11.** In many games F11 is the exclusive-fullscreen toggle, and one press locks you
> back to 30.

## 2. The GPU really is maxed out (the settings are genuinely too high)

If the GPU sits at 90%+, you genuinely don't have the performance. Cut settings in order of best
value for the cost:

| Change | Frame rate gain | Image quality cost |
|---|---|---|
| **Shader preset one notch down** (High → Medium) | large | small (shadow/reflection detail) |
| **Render distance 16 → 12** | medium | small (4 fewer chunks of view distance) |
| **Lower the simulation distance** | medium | medium (affects mob spawning/redstone) |
| **Turn off fancy clouds** | small | small |
| **Shadow render distance** (`maxShadowRenderDistance` in `iris.properties`) | medium | medium |
| **Lower the stream resolution** | large | large (the image goes soft) |
| **Turn shaders off** | huge | huge |

Rule of thumb: on a 4-core laptop with a Max-Q mobile GPU, at 2560×1664 with shaders, a reasonable
target is **60fps @ shaders on Medium**; if you want High/Ultra you'll have to drop to 1080p.

## 3. A trap in the Minecraft + Sodium UI

**Sodium's settings screen has `Undo` / `Apply` buttons.** Click only "Done" without clicking
"Apply" and your changes are **thrown away**.

How to tell whether something was committed: uncommitted entries show a `*` next to them.

```
Render Distance * 12 chunks   <- not committed
Render Distance   12 chunks   <- committed
```

In `options.txt`, that comes down to whether `renderDistance:12` was actually written.

## 4. The F3 debug screen is expensive by itself

With the full F3 debug screen open (especially once you've installed a pile of mods that add block
information, filling hundreds of lines down the right-hand side), the frame rate reads noticeably
lower.

**Turn F3 off before measuring frame rate**, or at least know that the bias is there.

While you're in there, the two lines that matter most:

```
60 fps / 120 fps (vsync)     <- current / cap
p50=60 p98=30 p99.5=30 fps   <- frame-time distribution, more useful than the instant value
```

`p50=60` means more than half your frames are full frames and only 2% dip to 30 — a far better
experience than "45fps average but constantly swinging".

## 5. Handling vsync

| Setting | Effect |
|---|---|
| **Vsync on** | On a 60Hz display it **snaps between 60 and 30** (come up just short of 60 and you're locked to 30) |
| **Vsync off + frame rate cap 60** | The frame rate floats smoothly between 40 and 60, which usually looks better |

For streaming, the client (Moonlight `--vsync`) already handles display synchronization, so leave
in-game vsync **off** and set the maximum frame rate to 60 (not 120 — that just burns GPU for
nothing).

## 6. Choosing a shader pack

Measured on the same machine, at the same resolution (2560×1664, targeting 60fps):

| Shader pack | GPU usage | Notes |
|---|---|---|
| **Complementary Reimagined** (Medium preset) | ~58% | Best-looking; shadows, reflections and volumetric light all present |
| **Solas** | ~80% | Modern look, on the bright side, fairly demanding |
| **MakeUp - Ultra Fast** | ~40% | Cheapest, plain visuals — good for weaker GPUs or if you want headroom |

**Dropping a preset beats switching shader packs**: taking Complementary from High down to Medium
gains an obvious amount of frame rate, and most people can't see the difference.

To change presets: in game, Options → Video Settings → Shader Packs → Shader Pack Settings →
Profile. It cycles through them (Potato / Very Low / Low / Medium / High / Very High / Ultra). The
setting is saved to `shaderpacks/<shader-pack-name>.txt` and survives a restart.

## 7. A diagnostic shortcut

When the frame rate looks wrong, ask yourself in this order:

1. **Is the GPU maxed out?** (`nvidia-smi -l 1`) If yes → cut image quality (section 2)
2. **GPU not maxed but the frame rate is pinned?** → fullscreen/vsync problem (sections 1 and 5)
3. **Does the frame rate change if you stop streaming?** No → it has nothing to do with streaming, keep working through 1 and 2
4. **Does the frame rate scale linearly with resolution?** Yes → pixel bandwidth bottleneck (see [performance.md](performance.md))
