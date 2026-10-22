# Maintenance: don't let updates take the box down

> 🌐 [中文](zh-CN/maintenance.md) ｜ **English**

A headless streaming box is a machine that **nobody looks at**. That is the whole point — and it is
also why a bad update can take it down for hours before anyone notices. These are the failure
modes we actually hit, in the order they hurt.

---

## 1. Pin the NVIDIA driver

`apt upgrade` happily moves you from one NVIDIA branch to the next (we went 610 → 615). The
userspace libraries get replaced, the running kernel module does not, and you get:

```
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 615.71

$ cat /proc/driver/nvidia/version
NVRAM version: ... Open Kernel Module for x86_64  610.43.02
```

That alone is harmless — **it means you must reboot**. The painful part is that a **major**
version jump can change how the driver handles custom modes and EDIDs, which is exactly the
machinery this repo depends on.

**Pin it:**

```bash
sudo apt-mark hold nvidia-driver-615-open nvidia-dkms-615-open nvidia-utils-615 \
     nvidia-kernel-source-615-open nvidia-kernel-common-615 \
     libnvidia-gl-615 xserver-xorg-video-nvidia-615
apt-mark showhold
```

When you *want* to upgrade: `apt-mark unhold …`, upgrade, reboot, re-run the verification
checklist at the bottom of this page, then hold again.

---

## 2. Plymouth can hang the boot at the splash

Symptom: the machine is powered on, the network is up (SSH works), but the screen sits on the
boot splash forever, and `systemctl start graphical.target` never returns.

```bash
$ systemctl list-jobs
JOB UNIT                       STATE
173 plymouth-quit-wait.service start running      ← stuck for 17 minutes
2   multi-user.target          start waiting
```

`plymouth-quit-wait` waits for the boot splash to exit. On NVIDIA + early KMS it sometimes never
does, which blocks `multi-user.target` — and therefore the desktop. There is **nothing in the
journal** explaining it; the logs just stop at a cron line.

**Fix (permanent):** don't draw a splash at all.

```bash
sudo sed -i 's/ splash//' /etc/default/grub
sudo update-grub
```

You lose the pretty logo and gain the kernel log — which is a good trade on a machine you debug
over SSH.

**Fix (a stuck machine, right now):**

```bash
sudo plymouth --quit
sudo systemctl stop plymouth-quit-wait
sudo systemctl restart gdm
```

---

## 3. Never `kill -9` a game launcher

We corrupted the Minecraft launcher's saved credentials by killing it hard while it was writing
them. The result:

- `launcher_accounts.json` shrank from 6081 bytes to 31 (`{"accounts":{},"activeAccount":null}`)
- `launcher_msa_credentials.bin` from 766 to 400 bytes
- The launcher shows an account picker with **"content not ready"**, and no **Play** button
- Automation that clicks Play silently fails — three attempts, then it gives up

Ask for a **clean close** instead:

```bash
# graceful: sends WM_DELETE_WINDOW
xdotool windowclose "$(xdotool search --classname com.mojang.minecraft | head -1)"

# if the app ignores WM_DELETE (Electron launchers often do), SIGTERM — never -9
pkill -TERM -f '[m]inecraft-launcher'
```

A hard power-off can corrupt these files the same way, which is one more reason to make the boot
reliable (see §2).

---

## 4. Long uptime is not a virtue

We had a box up for **19 days** with the discrete GPU running a headless X server the whole time.
It froze at 05:33 — SSH dead, keyboard dead — and the journal's last line was an ordinary cron
entry. No panic, no OOM, no error: a kernel-level lock-up, most likely the GPU driver.

Nothing to fix, everything to prevent: **reboot weekly**, and prefer a clean `reboot` over holding
the power button.

---

## 5. Verify after every kernel, driver or distro update

```bash
# driver
nvidia-smi --query-gpu=driver_version --format=csv,noheader
cat /proc/driver/nvidia/version | head -1          # must match the userspace version

# streaming display
systemctl is-active mc-xorg
DISPLAY=:200 xdpyinfo | grep dimensions            # expect your custom resolution

# EDID still readable? (the trick this repo depends on)
DISPLAY=:200 xsetroot -solid red && sleep 1
DISPLAY=:200 import -window root /tmp/t.png
convert /tmp/t.png -format '%[pixel:p{100,100}]' info:     # must print red
DISPLAY=:200 xsetroot -solid black

# encoder
systemctl --user is-active app-dev.lizardbyte.app.Sunshine
grep -a "Found H.264 encoder" ~/.config/sunshine/sunshine.log | tail -1
```

If the EDID test prints black, the driver changed how it handles `CustomEDID` /
`ConnectedMonitor` — see [headless-xorg.md](headless-xorg.md) and consider rolling the driver back.

---

## 6. Distro upgrades: not casually

`do-release-upgrade` replaces Xorg, the NVIDIA packaging and the kernel together. Everything this
repo configures lives in those three places. If you do it:

```bash
# back up first — these are the whole setup
cp ~/xorg-*.conf ~/nvidia-edid.bin ~/mc-xorg.env ~/stream-config-backup/
cp -r ~/.config/systemd/user/*.d/  ~/stream-config-backup/
sudo cp /etc/systemd/system/mc-xorg.service /etc/sudoers.d/mc-stream ~/stream-config-backup/
```

then expect an evening of re-verification, not a 10-minute job.
