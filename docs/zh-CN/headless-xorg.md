# Headless Xorg：让 X 服务器直接跑在显卡上

> 🌐 **中文** ｜ [English](../headless-xorg.md)

对应脚本：`scripts/20-setup-headless-xorg.sh` + `scripts/make-edid.py`

## 整体思路

要让游戏在「没有物理显示器」的机器上跑，需要骗过三样东西：

1. **显卡驱动**：让它以为某个输出接口上接了显示器 → `ConnectedMonitor`
2. **X 服务器**：让它为这个假显示器建立可用的帧缓冲 → **必须有 EDID**
3. **应用程序**：让它们看到一个合理的分辨率与 DPI → EDID 里的时序 + 物理尺寸

第 2 条是最容易踩的坑，见下。

## 坑一：没有 EDID，帧缓冲读不回来

如果你只写了 `AllowEmptyInitialConfiguration` + `ConnectedMonitor`，
Xorg 能正常启动，`xrandr` 也显示 2560×1664，`glxinfo` 也认得出显卡 ——
**但是所有抓屏都是纯黑**：

```bash
DISPLAY=:200 xsetroot -solid red          # 把根窗口刷成纯红
DISPLAY=:200 import -window root /tmp/a.png
convert /tmp/a.png -format '%[pixel:p{100,100}]' info:
#   → gray(0)     ← 黑。xwd、ffmpeg -f x11grab 也一样
```

Sunshine 抓到的也是黑的，于是串流出去就是**全黑画面**。

原因：没有 EDID 的「幽灵输出」在 NVIDIA 驱动里没有真正的扫描输出路径，
驱动不保证能把前缓冲读回来。

**解法**：给一个真的 EDID 文件（`make-edid.py` 就是生成它的）。

```apache
Option "CustomEDID" "DFP-0:/home/you/game-stream-edid.bin"
```

加上之后同一条命令立刻能抓到 `srgb(255,0,0)`。

> 顺带一提：EDID 可以用现成的（比如从别的显示器 dump 出来的 128 字节），
> 但那样分辨率就被那份 EDID 限死了。自己生成才能拿到想要的分辨率。

## 坑二：DPI 是由 EDID 的物理尺寸决定的

EDID 里除了时序，还有显示器的**物理尺寸（毫米）**。X 服务器用它来算 DPI：

```
DPI = 分辨率 / (物理尺寸 / 25.4)
```

如果尺寸填得不对（比如从笔记本内屏 EDID 抄来的 344×194mm），
在 2560×1664 下会算出 **191 DPI** —— 于是 Chromium/CEF 一类的程序
（**游戏启动器基本都是 CEF**）会把 UI 放大两倍，按钮跑到屏幕外面去，
你连「开始游戏」都点不到。

`make-edid.py` 反过来算：给定目标 DPI（默认 96），自动推出物理尺寸。

```bash
python3 scripts/make-edid.py --from-config scripts/config.env
#   时序      : 2560x1664 @ 59.97 Hz（像素时钟 362.25 MHz）
#   物理尺寸  : 680x440 mm  →  DPI 96x96
```

验证：

```bash
DISPLAY=:200 xdpyinfo | grep -E "dimensions|resolution"
#   dimensions:    2560x1664 pixels (680x440 millimeters)
#   resolution:    96x96 dots per inch
```

## 坑三：nvidia_drv.so 不在默认模块路径

Ubuntu 的 NVIDIA 包把它装在
`/usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so`，
不在 Xorg 默认搜索的 `/usr/lib/xorg/modules/drivers/` 下。
所以配置里要显式加 ModulePath：

```apache
Section "Files"
    ModulePath "/usr/lib/x86_64-linux-gnu/nvidia/xorg"
    ModulePath "/usr/lib/xorg/modules"
EndSection
```

不然会看到 `Failed to load module "nvidia"`。

## 输出连接器（ConnectedMonitor / CustomEDID 的名字）

无头机器上你需要编一个名字。查你显卡有哪些接口：

```bash
ls /sys/class/drm/         # 例如 card1-HDMI-A-1、card1-DP-1、card1-eDP-1
```

NVIDIA 驱动内部叫法通常是 `DFP-0`、`DFP-1`（数字接口）、`HDMI-0`、`DP-0`…
**笔记本独显一般没有直连输出，`DFP-0` 通常就能骗过去**（这也是默认值）。

自定义时序能不能用，还取决于：

```apache
Option "ModeValidation" "AllowNonEdidModes, NoEdidModes, NoMaxPClkCheck, \
       NoVertRefreshCheck, NoHorizSyncCheck, NoDFPNativeResolutionCheck, \
       NoVirtualSizeCheck, AllowInterlacedModes"
```

没有这一串，驱动会以「EDID 里没有这个模式」为由拒绝你的分辨率。

## 关于 `-ac`（关闭访问控制）

服务用 `Xorg ... -ac` 启动：`-ac` 关掉 X 的访问控制，同机普通用户
（Sunshine、xdotool、你的游戏）才能连上这个 display。

单用户自用机器没问题；如果是多人共用的机器，改成生成一个 Xauthority
并把 cookie 分发给需要用的人。

## 为什么用 systemd 服务而不是 nohup

```bash
systemctl status gamestream-xorg
sudo systemctl restart gamestream-xorg        # 已配免密
```

好处：
- 崩了自动重启（`Restart=always`）
- 开机自启
- 日志统一在 `/var/log/gamestream-xorg.log`
- 显示器编号放在 `~/gamestream-xorg.env`，改它不需要 root

## 换分辨率 / 换机器怎么做

```bash
# 1. 改 config.env 里的 STREAM_WIDTH / STREAM_HEIGHT / STREAM_DPI / XORG_OUTPUT
# 2. 重新生成 EDID
python3 scripts/make-edid.py --from-config scripts/config.env
# 3. 重新生成 Xorg 配置并重启
sudo bash scripts/20-setup-headless-xorg.sh
```

建议 **串流分辨率 = Mac 屏幕的原生分辨率**，这样客户端不需要缩放，最清晰：

| 机器 | 原生分辨率 |
|---|---|
| MacBook Air 13" | 2560×1664 |
| MacBook Pro 14" | 3024×1964 |
| MacBook Pro 16" | 3456×2234 |
| 外接 2K 显示器 | 2560×1440 |
