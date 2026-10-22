# 维护：别让升级把整台机器搞挂

> 🌐 **中文** ｜ [English](../maintenance.md)

一台无头串流机是**没人盯着看**的机器。这正是它的意义 —— 也正是为什么一次糟糕的升级
可以在几个小时内没人发现。下面这些是我们真实踩到的坑，按疼的程度排序。

---

## 1. 锁住 NVIDIA 驱动

`apt upgrade` 会毫不犹豫地把你从一个 NVIDIA 分支搬到下一个（我们从 610 跳到了 615）。
用户态库被替换，而正在运行的内核模块没有，于是：

```
$ nvidia-smi
Failed to initialize NVML: Driver/library version mismatch
NVML library version: 615.71

$ cat /proc/driver/nvidia/version
NVRAM version: ... Open Kernel Module for x86_64  610.43.02
```

这本身无害 —— **它只是意味着你必须重启**。真正麻烦的是**跨大版本**升级可能改变驱动
处理自定义模式和 EDID 的方式，而这恰恰是本仓库赖以工作的机制。

**锁住它：**

```bash
sudo apt-mark hold nvidia-driver-615-open nvidia-dkms-615-open nvidia-utils-615 \
     nvidia-kernel-source-615-open nvidia-kernel-common-615 \
     libnvidia-gl-615 xserver-xorg-video-nvidia-615
apt-mark showhold
```

哪天你想升级时：`apt-mark unhold …` → 升级 → 重启 → 跑一遍本文末尾的验证清单 → 再锁上。

---

## 2. Plymouth 会把启动卡在开屏画面上

症状：机器开着、网络通（SSH 能连）、但屏幕永远停在开机画面，而且
`systemctl start graphical.target` 永远不返回。

```bash
$ systemctl list-jobs
JOB UNIT                       STATE
173 plymouth-quit-wait.service start running      ← 卡了 17 分钟
2   multi-user.target          start waiting
```

`plymouth-quit-wait` 在等开屏动画退出。在 NVIDIA + early KMS 上它有时永远等不到，
于是阻塞了 `multi-user.target` —— 也就阻塞了桌面。**journal 里没有任何解释**，
日志就停在一条普通的 cron 记录上。

**永久修复：** 干脆不要开屏动画。

```bash
sudo sed -i 's/ splash//' /etc/default/grub
sudo update-grub
```

你会失去好看的 logo，换来真实的内核日志 —— 对一台靠 SSH 调试的机器来说，这笔交易划算。

**卡住时当场脱困：**

```bash
sudo plymouth --quit
sudo systemctl stop plymouth-quit-wait
sudo systemctl restart gdm
```

---

## 3. 绝对不要 `kill -9` 游戏启动器

我们就是在启动器写凭据的时候硬杀了它，把它的登录信息搞坏了。结果：

- `launcher_accounts.json` 从 6081 字节缩到 31（`{"accounts":{},"activeAccount":null}`）
- `launcher_msa_credentials.bin` 从 766 缩到 400 字节
- 启动器显示账号选择框，状态是 **"content not ready"**，没有「开始游戏」按钮
- 自动点「开始游戏」的脚本静默失败 —— 点三次，然后放弃

请改用**正常关闭**：

```bash
# 正常：发送 WM_DELETE_WINDOW
xdotool windowclose "$(xdotool search --classname com.mojang.minecraft | head -1)"

# 如果程序不理 WM_DELETE（Electron 启动器经常如此），用 SIGTERM —— 绝不用 -9
pkill -TERM -f '[m]inecraft-launcher'
```

硬断电也会以同样方式损坏这些文件，这也是让启动过程更可靠（见 §2）的又一个理由。

---

## 4. 长时间不重启不是美德

我们有一台机器连续开机 **19 天**，独显一直在跑无头 X 服务器。它在 05:33 冻住了
—— SSH 死、键盘死 —— 而 journal 的最后一行是一条普通的 cron 记录。没有 panic、没有 OOM、
没有报错：一个内核级的锁死，最可能是 GPU 驱动。

没什么可修的，全在预防：**每周重启一次**，并且用 `reboot` 而不是长按电源键。

---

## 5. 每次内核 / 驱动 / 发行版更新后都要验证

```bash
# 驱动
nvidia-smi --query-gpu=driver_version --format=csv,noheader
cat /proc/driver/nvidia/version | head -1          # 必须和用户态版本一致

# 串流虚拟屏
systemctl is-active mc-xorg
DISPLAY=:200 xdpyinfo | grep dimensions            # 应该还是你的自定义分辨率

# EDID 还能读吗？（本仓库依赖的那个把戏）
DISPLAY=:200 xsetroot -solid red && sleep 1
DISPLAY=:200 import -window root /tmp/t.png
convert /tmp/t.png -format '%[pixel:p{100,100}]' info:     # 必须输出红色
DISPLAY=:200 xsetroot -solid black

# 编码器
systemctl --user is-active app-dev.lizardbyte.app.Sunshine
grep -a "Found H.264 encoder" ~/.config/sunshine/sunshine.log | tail -1
```

如果 EDID 测试输出的是黑色，说明驱动改变了它处理 `CustomEDID` / `ConnectedMonitor` 的方式
—— 见 [headless-xorg.md](headless-xorg.md)，并考虑回滚驱动。

---

## 6. 发行版大版本升级：别随手做

`do-release-upgrade` 会一起替换 Xorg、NVIDIA 打包和内核。本仓库配置的一切都住在这三处。
如果你真要升：

```bash
# 先备份 —— 这就是整套配置
cp ~/xorg-*.conf ~/nvidia-edid.bin ~/mc-xorg.env ~/stream-config-backup/
cp -r ~/.config/systemd/user/*.d/  ~/stream-config-backup/
sudo cp /etc/systemd/system/mc-xorg.service /etc/sudoers.d/mc-stream ~/stream-config-backup/
```

然后请预留一个晚上的重新验证时间，而不是十分钟。
