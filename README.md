# Mac ← Linux 无头游戏串流

> 把一台**没有显示器**的 Linux 机器（NVIDIA 显卡）上的游戏，以 **2K / 60fps** 串流到 Mac。
> Sunshine（服务端）+ Moonlight（Mac 端），含全部踩坑记录和可直接改数值运行的脚本。

[English summary](#english-summary)

---

## 这个仓库解决什么问题

网上关于 Sunshine/Moonlight 的教程大多是「Windows 主机 + 有显示器」的场景。一旦换成
**无头 Linux + NVIDIA**，会连续踩到一串坑，而且每个坑的现象都很有迷惑性：

| 你看到的现象 | 真正的原因 | 在哪个文档 |
|---|---|---|
| 串流 2K 只有 **15fps**，换显卡/降画质都没用 | `Xvfb` 没有任何 GPU 加速接口，显卡渲染完要用 CPU 把每帧拷回来 | [docs/performance.md](docs/performance.md) |
| 抓屏全黑 / 串流全黑，但 X 服务器一切正常 | 无头 NVIDIA 输出**没有 EDID** 时帧缓冲读不回来 | [docs/headless-xorg.md](docs/headless-xorg.md) |
| 游戏启动器 UI 被放大两倍、按钮错位 | EDID 里的物理尺寸算出了 **191 DPI**，应该是 96 | [docs/headless-xorg.md](docs/headless-xorg.md) |
| 串流里**鼠标键盘完全没反应** | `/dev/uinput` 权限 + X 服务器不支持输入热插拔 | [docs/input.md](docs/input.md) |
| 鼠标一点进窗口就**消失、移不出来** | Moonlight 默认「相对鼠标 + 指针捕获」，远程桌面要用绝对鼠标 | [docs/macos-client.md](docs/macos-client.md) |
| 每隔几秒**轻微卡一下**，丢包率却不高 | macOS 的 **AWDL**（AirDrop 用的直连无线电）周期性抢占 Wi-Fi | [docs/network.md](docs/network.md) |
| 帧率**死锁在正好 30fps**，GPU 却只用了 47% | 游戏的**独占全屏**模式在无头显示上锁 30 | [docs/game-tuning.md](docs/game-tuning.md) |

---

## 架构

```
┌─ Linux 服务器（无显示器）─────────────────────────────┐
│                                                       │
│  Xorg :200  ← 直接跑在 NVIDIA 显卡上（headless）      │
│    · 自定义 EDID 提供 2560x1664@60 时序号与 96 DPI    │
│         ↑ 游戏渲染进显存，零拷贝                      │
│  Sunshine                                             │
│    · capture = x11（XCB 抓屏）+ NVENC 编码            │
│    · uinput 造虚拟键鼠 → Xorg 通过 udev 热插拔认领    │
└───────────────────────────────────────────────────────┘
                    ↓ 局域网 / Tailscale
┌─ Mac ─────────────────────────────────────────────────┐
│  Moonlight（--absolute-mouse --vsync）                │
│  AWDL 自动开关：串流时关、退出后恢复（不影响 AirDrop）│
└───────────────────────────────────────────────────────┘
```

---

## 快速开始

### 0. 前提

- **服务端**：Ubuntu/Debian 系，NVIDIA 显卡（已装官方驱动），能 SSH
- **客户端**：Mac + [Moonlight](https://moonlight-stream.org/)
- 两台机器在同一局域网（或都装了 Tailscale）

### 1. 克隆 & 配置

```bash
git clone https://github.com/<you>/mac-linux-game-streaming.git
cd mac-linux-game-streaming

cp scripts/config.env.example scripts/config.env
$EDITOR scripts/config.env      # ★ 只需要改这里：IP、用户名、分辨率
```

`config.env` 里每一项都有注释说明，所有脚本都从这里读值，**不需要去改脚本本身**。

### 2. 服务端：一次性初始化

把仓库拷到服务器（或直接在服务器上 clone），然后：

```bash
cd ~/mac-linux-game-streaming

# ① 装依赖（Xorg/Xvfb 工具、cvt 等）
bash scripts/10-install-deps.sh

# ② 生成自定义 EDID（分辨率/刷新率/DPI 从 config.env 读）
python3 scripts/make-edid.py --from-config scripts/config.env

# ③ 装 headless Xorg + systemd 服务 + 免密 sudo
sudo bash scripts/20-setup-headless-xorg.sh

# ④ 修 /dev/uinput 权限（否则 Sunshine 造不出虚拟键鼠）
sudo bash scripts/30-fix-input-permissions.sh
```

### 3. 服务端：配好 Sunshine 和游戏

```bash
bash scripts/40-configure-sunshine.sh    # 写 sunshine.conf（capture=x11 等必须项）
bash scripts/50-session-up.sh            # 拉起 Xorg + Sunshine + 启动器（幂等，可反复跑）
```

### 4. Mac 端

```bash
cp scripts/mac/start-stream.command ~/游戏串流.command
chmod +x ~/游戏串流.command
$EDITOR ~/游戏串流.command      # 改 STREAM_HOST_NAME / SSH 地址（或同样读 config.env）
```

双击运行即可。

**想让 AirDrop 在非串流时正常工作**（推荐）：

```bash
sudo bash scripts/mac/install-awdl-guard.sh
```

它会装一个守护：Moonlight 在串流时自动关掉 AWDL，退出后自动恢复。

---

## 目录结构

```
.
├── README.md
├── docs/
│   ├── architecture.md        # 架构与数据流
│   ├── performance.md         # 为什么不能用 Xvfb（含实测数据）
│   ├── headless-xorg.md       # headless NVIDIA Xorg + 自定义 EDID
│   ├── input.md               # 输入链路：uinput / uhid / 权限
│   ├── network.md             # 网络调优：AWDL、FEC、码率、有线 vs Wi-Fi
│   ├── macos-client.md        # Mac 端：Moonlight 参数、音频、快捷键
│   ├── game-tuning.md         # 游戏内画质与帧率调优（含 30fps 陷阱）
│   └── troubleshooting.md     # 故障速查表（现象 → 原因 → 命令）
├── scripts/
│   ├── config.env.example     # ★ 所有可配置项（复制成 config.env 后改）
│   ├── 10-install-deps.sh
│   ├── make-edid.py           # 生成自定义 EDID（任意分辨率/DPI）
│   ├── 20-setup-headless-xorg.sh
│   ├── 30-fix-input-permissions.sh
│   ├── 40-configure-sunshine.sh
│   ├── 50-session-up.sh
│   └── mac/
│       ├── start-stream.command
│       ├── awdl-guard.sh
│       └── install-awdl-guard.sh
└── LICENSE
```

---

## 实测效果（参考基线）

在一台「i7-11370H 4 核 + RTX 3070 Laptop Max-Q」的笔记本上，2560×1664 分辨率：

| 方案 | 帧率 | GPU 占用 |
|---|---|---|
| Xvfb 虚拟屏（网上教程的常见做法） | **15 fps** | 28%（显卡在等 CPU 拷贝） |
| 纯 CPU 软件渲染（llvmpipe） | 85 fps | — |
| **本文方案：headless Xorg 直跑显卡** | **60 fps** | 40~58% |

同一台机器、同一分辨率、同一个测试程序（glxgears）的对照，说明瓶颈在显示服务器而不在显卡。

---

## English summary

Stream a game running on a **headless Linux box with an NVIDIA GPU** to a Mac at 2K/60fps,
using Sunshine + Moonlight.

The naive approach (`Xvfb` as the virtual display) caps out at ~15fps at 1440p because Xvfb
has no GPU acceleration path — every frame must be copied back to it via the CPU
(measured ceiling ≈ 65 MPix/s). This repo instead runs a **real Xorg directly on the GPU**
with a **hand-crafted EDID** (required, otherwise the framebuffer can't be read back at all,
and the DPI comes out wrong), fixes the **uinput permissions** so Sunshine's virtual
mouse/keyboard reach the X server, disables **AWDL** on macOS while streaming (it causes
~100ms Wi-Fi blackouts every few seconds), and documents the traps
(in exclusive fullscreen the game is hard-locked to 30fps; Moonlight needs `--absolute-mouse`
and `--vsync` for desktop streaming, etc.).

Everything is parameterized in `scripts/config.env` — no need to edit the scripts.

---

## License

MIT — 随便用，出问题欢迎开 issue。
