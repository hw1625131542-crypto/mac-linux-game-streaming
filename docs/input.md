# 输入：让串流里的鼠标键盘真的动起来

对应脚本：`scripts/30-fix-input-permissions.sh`

## Sunshine 是怎么把输入送进游戏的

Sunshine 不用 XTest，它走的是**内核的 uinput/uhid**：

```
Moonlight 里的鼠标/键盘
      ↓ (网络)
Sunshine 收到输入事件
      ↓ 写进 /dev/uinput
内核创建虚拟设备：libvirtualhid Mouse / Keyboard / Gamepad
      ↓
X 服务器（或游戏自己）认领这些设备
```

这条链路有三个环节都可能断，而且症状长得差不多，要分开查。

## 环节一：/dev/uinput 权限

**症状**：串流里鼠标键盘完全没反应。Sunshine 日志里能看到：

```
Warning: Gamepad xseries is disabled due to gamepads.virtualhid-not-available
Warning: No gamepad input is available
```

**原因**：`/dev/uinput` 默认只有 root 能用。很多发行版靠 systemd-logind
给「当前活动会话」的用户临时挂一个 ACL 来过日子 —— 一旦那个 ACL 被清掉
（切换会话、SSH 登录、锁屏……），权限就退化成 root-only。

有个很坑的地方：ACL 残留会让 `ls -l` **看起来像基权限被改了**：

```bash
$ ls -l /dev/uinput
crw------- 1 root input 10, 223 /dev/uinput     # 看起来是 600
$ getfacl /dev/uinput
user::rw-
group::---
mask::---          # ← ACL mask 是 ---，把 group 位"遮"成了 ---
other::---
```

其实基权限可能还是 660，只是 mask 把权限遮住了。

**解法**（脚本做的事）：

```bash
sudo setfacl -b /dev/uinput /dev/uhid      # 清掉残留 ACL
sudo chmod 666 /dev/uinput /dev/uhid
```

并写 udev 规则永久生效：

```
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0666", OPTIONS+="static_node=uinput"
KERNEL=="uhid",   SUBSYSTEM=="misc", MODE="0666"
```

> 多人共用的机器请改成 `MODE="0660", GROUP="input"`，并把运行 Sunshine 的用户加进
> `input` 组。注意：**systemd 用户级服务不会自动继承新加的组**（用户管理器是登录时
> 启动的），要重新登录或者用 `sg input -c` 包一层。

## 环节二：X 服务器要能「看见」这些虚拟设备

**症状**：权限修好了，`/proc/bus/input/devices` 里能看到 `libvirtualhid Mouse`，
但鼠标还是不动。

**关键区别**：

| 虚拟屏 | 能否认领新出现的输入设备 |
|---|---|
| **Xvfb** | ❌ **不能**。它只在启动那一刻建好 core pointer/keyboard，之后新增的设备它完全看不见（`xinput list` 里只有 `Virtual core XTEST`） |
| **真 Xorg** | ✅ 能。走 udev 热插拔，`xinput list` 里会出现 `libvirtualhid Mouse/Keyboard` |

这就是为什么本方案一定要用真 Xorg（见 [performance.md](performance.md)），
顺带把输入问题也一起解决了。

验证：

```bash
DISPLAY=:200 xinput list | grep libvirtualhid
# ⎜   ↳ libvirtualhid Keyboard          id=16  [slave pointer]
# ⎜   ↳ libvirtualhid Mouse (Absolute)  id=18  [slave pointer]
#     ↳ libvirtualhid Keyboard          id=17  [slave keyboard]
```

> 如果你被迫只能用 Xvfb（比如显卡驱动实在装不上），还有一条兜底路：
> 写一个守护进程读 `/dev/input/eventXX`，再用 XTest 注入到 Xvfb 里。
> 本仓库早期版本就是这么干的（`mc-input-bridge.py`），能用但多一层转发；
> 换成真 Xorg 之后就不需要了，而且**必须停掉它**，否则会双重输入。

## 环节三：窗口管理器（容易被忽略）

**症状**：设备都在、`xinput` 也认了，但游戏窗口收不到键鼠。

X 的键盘事件是送给「有输入焦点」的窗口的。**没有窗口管理器就没有人设置焦点**，
新开的窗口默认拿不到焦点。

所以无头环境里必须跑一个轻量 WM：

```bash
openbox &
```

`50-session-up.sh` 会自动确保它在跑。

## 一个实用技巧：用 uinput 注入按键做自动化

如果你想在脚本里发按键（比如自动点某个界面），**XTest（xdotool key）在很多
游戏/CEF 程序里会被忽略**，而 uinput 造的虚拟键盘是"真设备"，一定能收到。

```python
# 造一个临时虚拟键盘，发一个 F3，然后销毁
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
time.sleep(2.5)                                   # 等 udev / Xorg 认领

def tap(code):                                    # KEY_F3 = 61
    for v in (1, 0):
        os.write(fd, struct.pack("llHHi", 0, 0, 1, code, v))
        os.write(fd, struct.pack("llHHi", 0, 0, 0, 0, 0))
        time.sleep(0.05)

tap(61)
time.sleep(0.5)
fcntl.ioctl(fd, UI_DEV_DESTROY)
```

## 排查顺序（照着走）

```bash
# 1. 会话建立后，内核里有没有虚拟设备？
grep -c libvirtualhid /proc/bus/input/devices     # 应为 5 左右
#   为 0 → 回到「环节一」查权限

# 2. X 服务器认没认领？
DISPLAY=:200 xinput list | grep libvirtualhid
#   空 → 用 Xvfb 了？或者 Xorg 需要重启让它重新热插拔

# 3. 有窗口管理器吗？
pgrep -x openbox

# 4. 直接看 X 有没有收到事件（排除游戏自身的问题）
DISPLAY=:200 xev | grep -A2 KeyPress
#   然后在串流里按个键，xev 有输出 → X 层是通的，问题在游戏/焦点
```
