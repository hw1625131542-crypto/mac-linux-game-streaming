# Mac client: the right Moonlight flags

> 🌐 [中文](zh-CN/macos-client.md) ｜ **English**

Related script: `scripts/mac/start-stream.command`

## Three flags you must pass

```bash
Moonlight stream "<host-name>" "Desktop" \
    --resolution 2560x1664 \
    --fps 60 \
    --bitrate 35000 \
    --display-mode windowed \
    --absolute-mouse \
    --vsync
```

### `--absolute-mouse` — without it, your mouse "disappears"

**Symptom**: the moment you click into the Moonlight window the cursor is gone. You can't move it
back out no matter what you try, and your only escape is switching Spaces (multiple desktops).

**Cause**: Moonlight defaults to *relative mouse + pointer capture*, which is designed for FPS
games — click into the window and it hides and locks the local cursor, then sends every movement to
the remote side as a relative delta.

For a **remote desktop** that's a disaster. With `--absolute-mouse`, the local cursor stays visible
and never gets locked, and the remote cursor follows your position one-to-one.

> If you do get locked in anyway (say you forgot the flag), these are Moonlight's shortcuts:
> `Ctrl+Alt+Shift+M` switches the mouse mode, `Ctrl+Alt+Shift+Q` quits the stream.
> You can confirm these bindings straight from the Moonlight binary:
> `strings /Applications/Moonlight.app/Contents/MacOS/Moonlight | grep "Ctrl+Alt"`

### `--vsync` — without it, the picture tears

Moonlight doesn't wait for vertical sync by default, so the image shows horizontal tearing. Add the
flag and it's fixed.

### `--display-mode windowed` — don't use fullscreen

Beyond the 30fps exclusive-fullscreen trap in [game-tuning.md](game-tuning.md), windowed mode is
simply easier to debug in a headless setup.
If you want the fullscreen look, just have the **server** strip the title bar off the game window
(`50-session-up.sh` adds the openbox rule for you).

## Common errors

### `module "QtQuick.Controls" plugin "qtquickcontrols2plugin" not found`

This always shows up when you launch Moonlight from the command line (double-clicking the app is
fine). You have to set the Qt plugin path explicitly:

```bash
export QT_PLUGIN_PATH="/Applications/Moonlight.app/Contents/PlugIns"
export QML2_IMPORT_PATH="/Applications/Moonlight.app/Contents/Resources/qml"
```

### `Found unexpected PC "XXX" looking for "YYY"`

The host name Moonlight recorded when you paired no longer matches the name Sunshine is currently
broadcasting. Set `sunshine_name` in the server's `sunshine.conf` to the same value as that entry in
Moonlight.

### Moonlight only allows a single instance

Run `pkill -x Moonlight` before launching from the command line, otherwise the new process exits
and you're still controlling the old window.

## Audio

**Symptom**: you have video but no sound.

First confirm the server-side chain is working — the game's audio should appear on Sunshine's
virtual sound card:

```bash
# On the server, while the game is running
XDG_RUNTIME_DIR=/run/user/$(id -u) pactl list sink-inputs | grep -E "Sink Input|application.name"
# You should see the game's audio stream, with Sink pointing at sink-sunshine-stereo
```

If the server side is fine, the problem is the Mac's **default output device**: it's often an
external display (audio over DisplayPort), and that display either has no speakers connected or has
its own volume at 0.

```bash
# Build the helper once (see scripts/mac/set-audio.swift)
swiftc -O scripts/mac/set-audio.swift -o ~/bin/set-audio

~/bin/set-audio                    # list every output device; ← marks the current default
~/bin/set-audio "MacBook"          # switch to the built-in speakers
~/bin/set-audio "DELL"             # switch back to the monitor / external speakers
```

## Keyboard shortcut cheat sheet

| Shortcut | Action |
|---|---|
| `Ctrl+Alt+Shift+M` | Toggle mouse mode (absolute ↔ relative capture) — press this when the cursor is locked |
| `Ctrl+Alt+Shift+Q` | Quit the stream |
| `Ctrl+Alt+Shift+S` | Toggle keyboard grab (lets system shortcuts like Alt+Tab reach the remote) |
| `Ctrl+Alt+Shift+X` | Toggle fullscreen |

(These can differ slightly between versions — confirm by searching the binary for `Ctrl+Alt` with
`strings`.)

## Gamepads

Xbox and PlayStation controllers work through Moonlight out of the box; the server creates a virtual
gamepad for them. One thing to keep in mind: **gamepads go through uhid, which is a completely
separate device path from the uinput used by mouse and keyboard**. For permission troubleshooting,
see [input.md](input.md).
