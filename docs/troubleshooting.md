# 故障速查

按「你看到的现象」找。每条都给了判断命令。

---

## 连不上 / 配对

| 现象 | 检查 |
|---|---|
| Moonlight 里看不到主机 | 服务端 Sunshine 在跑吗：`pgrep -x sunshine`；Web 界面能开吗：`https://<IP>:47990` |
| 配对失败 | 防火墙端口（见 [architecture.md](architecture.md#端口)）；Moonlight 有旧实例：`pkill -x Moonlight` |
| 报 `Found unexpected PC "X" looking for "Y"` | 主机名不一致。服务端 `sunshine.conf` 的 `sunshine_name` 要和 Moonlight 里那条记录一致 |
| 连上就断 | 看服务端 `~/.config/sunshine/sunshine.log`；常见是 `capture = x11` 没设 |

---

## 画面

| 现象 | 原因 / 处理 |
|---|---|
| **全黑，但 X 服务器正常** | EDID 没生效。见 [headless-xorg.md](headless-xorg.md)。验证：`DISPLAY=:200 xsetroot -solid red; import -window root /tmp/a.png; convert /tmp/a.png -format '%[pixel:p{10,10}]' info:` 应该是红色 |
| **帧率死锁 15fps** | 虚拟屏退回 Xvfb 了。`pgrep -af "Xorg :200"` 应该是 `/usr/lib/xorg/Xorg`；见 [performance.md](performance.md) |
| **帧率死锁正好 30fps** | 游戏在独占全屏。见 [game-tuning.md](game-tuning.md#一帧率死锁在正好-30fps)。判定特征：GPU 只用 40~60%，且停掉串流帧率也不变 |
| **画面横向撕裂** | Moonlight 少了 `--vsync` |
| **画面糊 / 马赛克** | 码率被自适应压低了。查 AWDL（[network.md](network.md)）和码率设置 |
| **抓到的是纯黑图** | 同"全黑"一条，EDID |
| 画面卡住不动、日志一直 `Waiting for IDR frame` | 链路丢包严重。查 AWDL / 降码率 |
| 串流窗口比画面小、有黑边 | 串流分辨率的长宽比和 Moonlight 窗口不一致。把 `STREAM_WIDTH/HEIGHT` 设成 Mac 屏幕原生分辨率 |

---

## 输入

| 现象 | 原因 / 处理 |
|---|---|
| **鼠标键盘完全没反应** | ① `grep -c libvirtualhid /proc/bus/input/devices` 应为 5 左右；为 0 → `sudo bash scripts/30-fix-input-permissions.sh`；② 再 `sudo -n systemctl restart gamestream-xorg` 让 Xorg 重新热插拔；③ 确认 openbox 在跑（没有 WM 就没有焦点） |
| **鼠标一点进窗口就消失、移不出来** | Moonlight 少了 `--absolute-mouse`。临时救急：`Ctrl+Alt+Shift+M` |
| 键鼠只在某些程序里失效 | 大概率是那个程序用了 XInput2 raw 模式。试 `--no-game-optimization`，或者用 uinput 注入（见 [input.md](input.md#一个实用技巧用-uinput-注入按键做自动化)） |
| 手柄没反应 | 手柄走 uhid，和键鼠的 uinput 是两套。检查 `/dev/uhid` 权限；游戏内还需要手柄支持（SDL） |

---

## 声音

| 现象 | 处理 |
|---|---|
| 有画面没声音 | ① 服务端链路：游戏运行时 `pactl list sink-inputs \| grep -A2 "Sink Input"` 应该看到游戏音频指向 `sink-sunshine-stereo`；② Mac 默认输出设备：`~/bin/set-audio` 列出来看看是不是切到显示器去了 |
| 声音断续 | 音频包成组丢失。看 Moonlight 日志里的 `Unable to recover audio data block`。对策同画面卡顿（AWDL / 降码率） |

---

## 服务端组件

```bash
# 显示服务器
systemctl status gamestream-xorg
sudo systemctl restart gamestream-xorg        # 已配免密
tail -40 /var/log/gamestream-xorg.log

# 串流服务
systemctl --user status sunshine
systemctl --user restart sunshine
tail -40 ~/.config/sunshine/sunshine.log

# 窗口管理器（没有它键鼠进不了游戏）
pgrep -x openbox || (setsid openbox &)

# 一键重来（幂等）
bash scripts/50-session-up.sh
```

---

## 快速体检脚本

```bash
DISP=:200

echo "== X 服务器 =="; pgrep -af "Xorg $DISP" || echo "  ✗ 没在跑"
echo "== 分辨率/DPI =="; DISPLAY=$DISP xdpyinfo | grep -E "dimensions|resolution"
echo "== 渲染器 =="; DISPLAY=$DISP glxinfo 2>/dev/null | grep "OpenGL renderer"
echo "== 帧缓冲 =="; DISPLAY=$DISP xsetroot -solid red; sleep 1
                    DISPLAY=$DISP import -window root /tmp/_t.png 2>/dev/null && \
                    convert /tmp/_t.png -format '  %[pixel:p{10,10}]\n' info:
                    DISPLAY=$DISP xsetroot -solid black
echo "== 虚拟输入设备 =="; grep -c libvirtualhid /proc/bus/input/devices
echo "== Xorg 认领的输入 =="; DISPLAY=$DISP xinput list 2>/dev/null | grep -c libvirtualhid
echo "== 窗口管理器 =="; pgrep -x openbox >/dev/null && echo "  ✓" || echo "  ✗"
echo "== Sunshine =="; pgrep -x sunshine >/dev/null && echo "  ✓" || echo "  ✗"
echo "== GPU =="; nvidia-smi --query-gpu=utilization.gpu,memory.used,power.draw --format=csv,noheader
```

正常输出应该像：

```
== X 服务器 ==     12345 /usr/lib/xorg/Xorg :200 -config ...
== 分辨率/DPI ==   dimensions: 2560x1664 pixels (680x440 millimeters)
                   resolution: 96x96 dots per inch
== 渲染器 ==       OpenGL renderer string: NVIDIA GeForce RTX 3070 Laptop GPU/PCIe/SSE2
== 帧缓冲 ==       srgb(255,0,0)          ← 红色 = EDID 生效
== 虚拟输入设备 == 5
== Xorg 认领的输入 == 4
== 窗口管理器 ==   ✓
== Sunshine ==     ✓
```
