# 网络：把「轻微卡顿」彻底干掉

> 🌐 **中文** ｜ [English](../network.md)

游戏串流对网络的容忍度比想象中低得多：平均延迟高一点没事，
**抖动（jitter）和突发丢包**才是杀手。

## 一、macOS 的 AWDL：最容易被冤枉的元凶

### 症状

- 每隔几秒轻微卡一下，说不清规律
- 丢包率看着不高（ping 都不丢包）
- 服务端日志里是**突发丢包**：一次丢 4~13 个包
- Sunshine/Moonlight 的自适应码率一路往下掉，越掉越糊，但卡顿依旧

### 原因

Mac 上有个叫 **AWDL**（Apple Wireless Direct Link）的东西，是 AirDrop、
接力（Handoff）、通用剪贴板、隔空播放用的**直连无线电**。
它会周期性把 Wi-Fi 电台切到"社交信道"约 **100 毫秒** —— 这 100ms 里所有包全丢。

```
$ ifconfig awdl0
awdl0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
                  ↑↑↑ 这个 UP 就是它开着的证据
```

### 实测数据

同一台 Mac、同一个 ping 目标、同样 60 个包：

| | 抖动 max | 抖动 mdev |
|---|---|---|
| 开着 AWDL | **63.7 ms** | 12.7 ms |
| 关掉 AWDL | **7.6 ms** | 1.4 ms |

串流侧的连带效果：Moonlight 的自适应码率从被压到的 **5 Mbps** 恢复到 **52 Mbps**，
丢帧次数归零。

### 为什么 FEC 救不了

Sunshine 有前向纠错（`fec_percentage`），能补**零散**丢包。
但 AWDL 造成的是**突发**：一帧视频才 4~7 个包，一口气丢 4~13 个，FEC 补不回来。
实测把 FEC 从 40% 加到 80% 也没用，因为那是丢包形态的问题，不是量的问题。

日志长这样：

```
Unrecoverable frame 1106: 2+2=4 received < 5 needed     ← 一帧只要 5 个包
Unrecoverable frame 1515: 0+1=1 received < 5 needed     ← 5 个包里丢了 4 个
                                    ↑
                          加号后面是 FEC 救回来的数量
```

### 两个解法

**方案 A：串流时自动关，退出后恢复**（推荐，AirDrop 照常可用）

```bash
sudo bash scripts/mac/install-awdl-guard.sh
```

它装一个 LaunchDaemon：检测到 Moonlight 在串流就 `ifconfig awdl0 down`，
退出就 `up`。

**方案 B：一直关着**

```bash
sudo ifconfig awdl0 down
```

代价是 AirDrop / 接力 / 通用剪贴板失效。

### 验证方法

```bash
# 串流开着的时候，从服务器 ping Mac，看抖动
ping -c 60 -i 0.1 <Mac的IP>
# mdev 应该 < 2ms；如果 > 10ms 就该查 AWDL 了
```

## 二、码率怎么定

经验值（配合 `fec_percentage` 一起调）：

| 链路 | 建议码率 | FEC |
|---|---|---|
| 千兆有线 | 50000~80000 Kbps | 20 |
| 百兆有线 | 35000~45000 Kbps | 30 |
| Wi-Fi 5GHz 同房间 | 25000~40000 Kbps | 40~60 |
| Wi-Fi 信号一般 | 15000~25000 Kbps | 60 |

注意 **FEC 会按比例增加实际带宽占用**：`fec_percentage = 40` 时，
35 Mbps 的视频实际要占 ~49 Mbps。

```ini
# ~/.config/sunshine/sunshine.conf
fec_percentage = 40
```

## 三、看日志判断问题类型

Moonlight 的日志（`/tmp/Moonlight-*.log`）里：

| 日志 | 含义 | 对策 |
|---|---|---|
| `Network dropped 1 frame (frame N)` | 某帧的包没收齐 | 提高 FEC |
| `Unrecoverable frame N: a+b=c received < d needed` | 丢太多，FEC 也补不回来 | 降码率 / 修 AWDL |
| `Unable to recover audio data block` | 音频包成组丢失 | 同上（音频包是 4 个一组） |
| `Connection status update: 1` | 客户端判定链路变差 | 自适应码率会开始降 |

## 四、别忽略的几点

**串流走局域网，不要走内网穿透。** 检查方法（在服务器上）：

```bash
# 看视频流从哪个网卡出去
for i in eno1 tailscale0; do
  a=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0); sleep 5
  b=$(cat /sys/class/net/$i/statistics/tx_bytes 2>/dev/null || echo 0)
  echo "$i: $(( (b-a)*8/5/1000000 )) Mbps"
done
```

视频应该从局域网网卡出去（几十 Mbps），Tailscale/隧道网卡接近 0。
Tailscale 虽然方便，但一旦走 DERP 中继，延迟和抖动都会很难看。

**5GHz 信道别和邻居撞。** macOS 可以看周围网络：

```bash
system_profiler SPAirPortDataType | grep -A3 "Other Local Wi-Fi Networks"
```

如果你的信道和邻居的 80MHz 块重叠（比如你 157、邻居 149，同属 149-161 那一段），
换到 36-48 或 100-112 会干净很多。

**有线永远最好。** Mac 用 USB-C 转网口，上面所有问题一次性消失。
