# Mac 端：Moonlight 的正确参数

对应脚本：`scripts/mac/start-stream.command`

## 三个必须加的参数

```bash
Moonlight stream "<主机名>" "Desktop" \
    --resolution 2560x1664 \
    --fps 60 \
    --bitrate 35000 \
    --display-mode windowed \
    --absolute-mouse \
    --vsync
```

### `--absolute-mouse` —— 不加的话鼠标会「消失」

**症状**：鼠标一点进 Moonlight 窗口就看不见了，怎么移都移不出来，
只能切 Space（多桌面）逃出来。

**原因**：Moonlight 默认用「相对鼠标 + 指针捕获」，那是给 FPS 游戏设计的：
一点进窗口就把本地光标隐藏并锁住，把所有移动当相对位移发给远端。

对**远程桌面**这是灾难。加上 `--absolute-mouse` 之后：本地光标始终可见、
不会被锁，远端光标跟着你的位置一一对应。

> 万一还是被锁住了（比如忘了加参数），Moonlight 的快捷键：
> `Ctrl+Alt+Shift+M` 切换鼠标模式，`Ctrl+Alt+Shift+Q` 退出串流。
> 这几个键位可以从 Moonlight 二进制里确认：
> `strings /Applications/Moonlight.app/Contents/MacOS/Moonlight | grep "Ctrl+Alt"`

### `--vsync` —— 不加的话画面撕裂

Moonlight 默认不等垂直同步，画面会出现横向撕裂。加上就好。

### `--display-mode windowed` —— 别用全屏

除了下面那节讲的 30fps 陷阱，窗口模式在无头环境里也更好调试。
想要满屏观感的话，在**服务端**给游戏窗口去掉标题栏就够了
（`50-session-up.sh` 会自动加 openbox 规则）。

## 常见报错

### `module "QtQuick.Controls" plugin "qtquickcontrols2plugin" not found`

从命令行启动 Moonlight 时必现（GUI 双击没事）。必须显式指定 Qt 插件路径：

```bash
export QT_PLUGIN_PATH="/Applications/Moonlight.app/Contents/PlugIns"
export QML2_IMPORT_PATH="/Applications/Moonlight.app/Contents/Resources/qml"
```

### `Found unexpected PC "XXX" looking for "YYY"`

Moonlight 里配对时记录的主机名，和现在 Sunshine 广播的名字不一致。
把服务端 `sunshine.conf` 里的 `sunshine_name` 和 Moonlight 里那条记录改成一样的。

### Moonlight 只允许单实例

命令行启动前先 `pkill -x Moonlight`，否则新进程会退出、你控制的是旧窗口。

## 声音

**症状**：有画面没声音。

先确认服务端链路是通的 —— 游戏音频应该出现在 Sunshine 的虚拟声卡上：

```bash
# 服务器上，游戏运行时
XDG_RUNTIME_DIR=/run/user/$(id -u) pactl list sink-inputs | grep -E "Sink Input|application.name"
# 应该能看到游戏的音频流，Sink 指向 sink-sunshine-stereo
```

如果服务端正常，那问题在 Mac 的**默认输出设备**：经常是外接显示器
（走 DisplayPort 音频），而那台显示器没接音响、或者显示器自己的音量是 0。

```bash
# 编译一次小工具（见 scripts/mac/set-audio.swift）
swiftc -O scripts/mac/set-audio.swift -o ~/bin/set-audio

~/bin/set-audio                    # 列出所有输出设备，带 ← 的是当前默认
~/bin/set-audio "MacBook"          # 切到内置扬声器
~/bin/set-audio "DELL"             # 切回显示器/外接音响
```

## 快捷键速查

| 快捷键 | 作用 |
|---|---|
| `Ctrl+Alt+Shift+M` | 切换鼠标模式（绝对 ↔ 相对捕获）—— 光标被锁住时按这个 |
| `Ctrl+Alt+Shift+Q` | 退出串流 |
| `Ctrl+Alt+Shift+S` | 切换键盘抓取（让 Alt+Tab 之类的系统快捷键传给远端） |
| `Ctrl+Alt+Shift+X` | 切换全屏 |

（不同版本可能略有差异，用 `strings` 在二进制里搜 `Ctrl+Alt` 确认。）

## 手柄

Xbox / PS 手柄通过 Moonlight 直接可用，服务端会创建一个虚拟手柄。
需要注意的是：**手柄走的是 uhid，和鼠标键盘的 uinput 是两套设备**，
权限问题的排查见 [input.md](input.md)。
