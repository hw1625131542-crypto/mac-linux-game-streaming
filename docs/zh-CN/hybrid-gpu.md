# 混合显卡：当这台机器同时还要跑桌面

> 🌐 **中文** ｜ [English](../hybrid-gpu.md)

本仓库其余部分都假设这是一台**无头**机器：没有显示器、没有桌面，只有一个跑在 `:200` 上的
串流 X 服务器。这套假设很干净 —— 直到这台机器其实是一台**你平时也在用的笔记本**，
只有一张独显，而你确实需要桌面。

这篇讲的就是这种情况，因为它的失败方式非常容易误判。

---

## 问题：一张显卡，只能有一个 DRM master

Linux 的 DRM 子系统同一时刻**只允许一张显卡有一个 master**。master 就是打开设备并接管
模式设置的那个进程 —— 通常就是桌面的 X 服务器。

所以当你的桌面会话（比如 GNOME 走 PRIME）正在运行并持有 NVIDIA 显卡时：

```
mc-xorg  →  (EE) NVIDIA(GPU-0): Failed to acquire modesetting permission.
            (EE) NVIDIA(0): Failing initialization of X screen
            (EE) no screens found
```

……串流 X 服务器直接退出。`Restart=always` 会让它无限重试，于是你看到一个在 `activating`
之间反复横跳的服务，和一个永远不存在的 `:200`。

反过来也一样失败，而这才是最让人困惑的地方：如果 `mc-xorg` **先**启动并拿走了显卡，
失败的就变成了**桌面** —— gdm 启动、尝试拉起它的 X 服务器、然后退出。你看到的是
**一个空终端加一个闪烁光标**，以及：

```bash
$ systemctl is-active graphical.target
inactive
$ ls /tmp/.X11-unix/
X200                        # 只有串流的显示
```

**调整启动顺序解决不了这个问题。** 单显卡上不存在一个"两边都能拿到"的时刻。
这是互斥，不是竞态。

---

## 确认诊断

```bash
# 1. 现在处于哪个模式？
systemctl is-active gdm          # 桌面
systemctl is-active mc-xorg      # 串流虚拟屏

# 2. 显卡到底在谁手里？
journalctl -b | grep -iE "gdm-x-session.*nvidia" | tail -3
#   出现 Loading nvidia_drv.so / libglxserver_nvidia.so → 桌面拿着

# 3. 铁证
grep -a "modesetting permission" /var/log/mc-xorg.log | tail -3

# 4. 屏幕上现在是哪个 VT？（空终端 = 登录界面没接管）
cat /sys/class/tty/tty0/active
```

---

## 模式：互斥切换

两个脚本，各把机器带到一个状态。没有守护进程替你做决定 —— 机器处于你最后一次要求的
状态，而"串流"这个状态由 Mac 上的一键脚本触发。

### `mode-streaming.sh`

```bash
systemctl stop gdm          # 让出显卡
systemctl start mc-xorg     # 启动无头 X 服务器
systemctl --user start sunshine
```

### `mode-desktop.sh`

```bash
systemctl --user stop sunshine
systemctl stop mc-xorg
systemctl start gdm
```

两个脚本都需要 root 来调 `systemctl`，所以配一条**范围很窄**的 sudoers 规则，
而不是把整个脚本用 root 跑：

```sudoers
you ALL=(root) NOPASSWD: /usr/bin/systemctl start mc-*, /usr/bin/systemctl stop mc-*, \
                          /usr/bin/systemctl start gdm, /usr/bin/systemctl stop gdm
```

同时**取消串流服务的开机自启**，这样冷启动会落到桌面上：

```bash
sudo systemctl disable mc-xorg
```

于是日常循环变成：

| 你做什么 | 机器做什么 |
|---|---|
| 开机 | 直接进桌面、登录界面 |
| 双击 Mac 上的一键脚本 | 停 gdm → 起 `mc-xorg` + Sunshine → 启动游戏 |
| 关掉 Moonlight | （可选，见下）关闭游戏 → 回到桌面 |

---

## 这个模式里的两个坑

### 1. 第二个 X 服务器会抢走虚拟终端

显卡问题解决之后，在登录界面已经在跑的情况下启动 `mc-xorg`，**屏幕还是会变黑**：
X 会给自己分配一个 VT 并**切换过去**，于是登录界面还在 `tty1` 上跑着，但你看的是 `tty2`。

加 `-novtswitch`（同时**不要**加 `-sharevts` —— 它帮不上忙，还可能导致 modeset 失败）：

```ini
ExecStart=/usr/lib/xorg/Xorg ${GS_DISPLAY} -config ... -noreset -nolisten tcp -ac -novtswitch
```

用 `cat /sys/class/tty/tty0/active` 验证 —— 它应该一直停在登录界面那个 VT 上。

### 2. Sunshine 被绑在图形会话上

发行版打包的 Sunshine 用户服务里写着：

```ini
[Install]
WantedBy=graphical-session.target
```

登录界面一旦失败，`graphical-session.target` 就永远不会激活 —— 于是 **Sunshine 永远不启动**，
你得到一个正常工作的 X 服务器，但没有任何东西在监听。这就是为什么"桌面坏了"会
**静默地意味着"串流也坏了"**。

解开这个依赖：

```ini
# ~/.config/systemd/user/app-dev.lizardbyte.app.Sunshine.service.d/10-independent-of-desktop.conf
[Install]
WantedBy=default.target
```

然后 `systemctl --user daemon-reload && systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`。

---

## 可选：断开后自动回到桌面

如果你只在打算玩的时候串流，一个小守护可以让切回自动化：检测到 Sunshine 客户端断开 →
干净地关闭游戏 → 执行 `mode-desktop.sh`。

值得照抄的几条护栏：

- **30 秒宽限期** —— 网络抖一下不该把会话干掉
- **用窗口关闭消息关游戏**，不要 `kill -9`，让它正常存档
- **只在 `mc-xorg` 处于 active 时才动手**，避免过期的守护把桌面抽走
- **数连接次数，不要解析时间戳**：从 `~/.config/sunshine/sunshine.log` 里
  数 `CLIENT CONNECTED` 减 `CLIENT DISCONNECTED`

配套脚本见 `scripts/60-mode-switch.sh`（两个模式）和 `scripts/61-auto-return.sh`（守护）。

---

## 如果两边真的必须同时运行

只有一种可能：桌面**完全不碰独显**。混合显卡笔记本的内屏和 USB-C/DP 输出通常接在
**核显**上，所以跑在 `i915`/`amdgpu` 上的桌面可以和独显上的无头 X 服务器共存：

```xorg
# /etc/X11/xorg.conf.d/10-igpu-only.conf
Section "Device"
    Identifier "igpu"
    Driver     "modesetting"
    BusID      "PCI:0:2:0"
EndSection
```

代价是实打实的：桌面 X 服务器里没有 NVIDIA 驱动，**本地游戏的 PRIME 加速就没了** ——
在本机启动的游戏会跑在核显上。如果这台机器上要玩什么吃性能的东西，这笔交易不划算。

| 方案 | 桌面 | 串流 | 本地游戏用独显 |
|---|---|---|---|
| 只用桌面 | ✅ | ❌ | ✅ |
| 只用串流 | ❌ | ✅ | ❌ |
| **互斥切换（本文）** | ✅ | ✅（同一时间只有一个） | ✅ |
| 桌面用核显 | ✅ | ✅ **可同时** | ❌ |

---

## 检查清单

```
[ ] sudo systemctl disable mc-xorg           # 开机进桌面
[ ] gdm 启停的 sudoers 规则
[ ] mc-xorg 的 ExecStart 里加 -novtswitch
[ ] Sunshine 服务：WantedBy=default.target
[ ] mode-streaming.sh / mode-desktop.sh 两个方向都测过
[ ] 验证：桌面模式下 ls /tmp/.X11-unix/ 有 X0，串流模式下有 X200
[ ] 验证：桌面模式下 cat /sys/class/tty/tty0/active 停在 tty1
```
