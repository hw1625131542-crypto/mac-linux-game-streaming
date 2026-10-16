# Input: making the mouse and keyboard actually work in the stream

> 🌐 [中文](zh-CN/input.md) ｜ **English**

Script: `scripts/30-fix-input-permissions.sh`

## How Sunshine gets input into the game

Sunshine doesn't use XTest — it goes through the **kernel's uinput/uhid**:

```
Mouse/keyboard in Moonlight
      ↓ (network)
Sunshine receives the input events
      ↓ writes to /dev/uinput
the kernel creates virtual devices: libvirtualhid Mouse / Keyboard / Gamepad
      ↓
the X server (or the game itself) claims those devices
```

There are three links in that chain that can break, and they all present much the same symptoms, so
check them one at a time.

## Stage 1: /dev/uinput permissions

**Symptom**: the mouse and keyboard do absolutely nothing in the stream. In Sunshine's log you'll
see:

```
Warning: Gamepad xseries is disabled due to gamepads.virtualhid-not-available
Warning: No gamepad input is available
```

**Cause**: `/dev/uinput` is root-only by default. Plenty of distros get away with an ACL that
systemd-logind temporarily attaches for the user of the "currently active session" — as soon as that
ACL is cleared (switching sessions, logging in over SSH, locking the screen, ...), permissions
degrade to root-only.

There's a nasty detail here: a leftover ACL makes `ls -l` **look like the base permissions were
changed**:

```bash
$ ls -l /dev/uinput
crw------- 1 root input 10, 223 /dev/uinput     # looks like 600
$ getfacl /dev/uinput
user::rw-
group::---
mask::---          # ← the ACL mask is ---, which "hides" the group bits as ---
other::---
```

In reality the base permissions may still be 660 — the mask is just hiding them.

**The fix** (what the script does):

```bash
sudo setfacl -b /dev/uinput /dev/uhid      # clear the leftover ACL
sudo chmod 666 /dev/uinput /dev/uhid
```

Then write udev rules so it sticks:

```
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0666", OPTIONS+="static_node=uinput"
KERNEL=="uhid",   SUBSYSTEM=="misc", MODE="0666"
```

> On a shared machine, change that to `MODE="0660", GROUP="input"` and add the user running Sunshine
> to the `input` group. Careful: **systemd user services do not automatically inherit newly added
> groups** (the user manager starts at login), so you have to log in again or wrap the command with
> `sg input -c`.

## Stage 2: the X server has to be able to "see" those virtual devices

**Symptom**: permissions are fixed and `/proc/bus/input/devices` shows `libvirtualhid Mouse`, but the
mouse still won't move.

**The critical difference**:

| Virtual display | Can it claim input devices that show up later? |
|---|---|
| **Xvfb** | ❌ **No.** It builds its core pointer/keyboard once at startup and never sees devices added afterwards (`xinput list` only ever shows `Virtual core XTEST`) |
| **Real Xorg** | ✅ Yes. It goes through udev hotplug, so `libvirtualhid Mouse/Keyboard` appears in `xinput list` |

That's why this project insists on a real Xorg (see [performance.md](performance.md)) — and it
happens to fix the input problem along the way.

Verify:

```bash
DISPLAY=:200 xinput list | grep libvirtualhid
# ⎜   ↳ libvirtualhid Keyboard          id=16  [slave pointer]
# ⎜   ↳ libvirtualhid Mouse (Absolute)  id=18  [slave pointer]
#     ↳ libvirtualhid Keyboard          id=17  [slave keyboard]
```

> If you're forced onto Xvfb (say the GPU driver simply won't install), there's one fallback: write a
> daemon that reads `/dev/input/eventXX` and injects into Xvfb with XTest. Early versions of this
> repo did exactly that (`mc-input-bridge.py`). It works, but it adds a forwarding layer; once you
> move to a real Xorg you don't need it — and you **must shut it down**, or you get double input.

## Stage 3: the window manager (easy to overlook)

**Symptom**: the devices are all there and `xinput` sees them, but the game window never receives
anything.

X delivers key events to whichever window **holds the input focus**. **With no window manager,
nobody sets the focus**, and a newly opened window gets none by default.

So a headless environment needs a lightweight WM:

```bash
openbox &
```

`50-session-up.sh` makes sure one is running.

## A handy trick: use uinput key injection for automation

If you want to send keystrokes from a script (to click through some UI automatically, for instance),
**XTest (`xdotool key`) gets ignored by a lot of games and CEF apps**, whereas a virtual keyboard
created through uinput is a "real device" and is always received.

```python
# create a temporary virtual keyboard, send one F3, then destroy it
import fcntl, os, struct, time
UI_SET_EVBIT, UI_SET_KEYBIT = 0x40045564, 0x40045565
UI_DEV_CREATE, UI_DEV_DESTROY = 0x5501, 0x5502

fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
fcntl.ioctl(fd, UI_SET_EVBIT, 1)                 # EV_KEY
for k in range(1, 256):
    fcntl.ioctl(fd, UI_SET_KEYBIT, k)
desc = struct.pack("80sHHHHi", b"keyinject", 0x03, 0x1234, 0x5678, 1, 0) + b"\x00" * 1024
os.write(fd, desc)
fcntl.ioctl(fd, UI_DEV_CREATE)
time.sleep(2.5)                                   # wait for udev / Xorg to claim it

def tap(code):                                    # KEY_F3 = 61
    for v in (1, 0):
        os.write(fd, struct.pack("llHHi", 0, 0, 1, code, v))
        os.write(fd, struct.pack("llHHi", 0, 0, 0, 0, 0))
        time.sleep(0.05)

tap(61)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
```

## Debugging order (just follow it)

```bash
# 1. Once the session is up, are there virtual devices in the kernel?
grep -c libvirtualhid /proc/bus/input/devices     # should be around 5
#   0 → go back to Stage 1 and check permissions

# 2. Has the X server claimed them?
DISPLAY=:200 xinput list | grep libvirtualhid
#   empty → are you on Xvfb? or does Xorg need a restart so it re-runs hotplug?

# 3. Is there a window manager?
pgrep -x openbox

# 4. Look directly at whether X receives the events (rules out the game itself)
DISPLAY=:200 xev | grep -A2 KeyPress
#   now press a key in the stream; if xev prints something, the X layer is fine and the problem is the game/focus
```
