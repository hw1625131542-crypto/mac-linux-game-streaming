#!/bin/bash
# ---------------------------------------------------------------------------
#  ENGLISH SUMMARY
#  Disables AWDL — Apple Wireless Direct Link, the radio behind AirDrop and
#  Handoff — while Moonlight is streaming, and restores it afterwards, so
#  AirDrop keeps working when you are not gaming.
#
#  Why: AWDL periodically retunes the Wi-Fi radio to a "social channel" for
#  ~100ms. In that window everything is lost, in bursts of 4-13 packets, which
#  is exactly the shape that forward error correction cannot repair. Measured
#  jitter drops from 63.7ms (max) / 12.7ms (mdev) to 7.6ms / 1.4ms when AWDL is
#  off, and the stream's adaptive bitrate recovers to full.
#  Comments below are in Chinese / 下面的注释是中文。
# ---------------------------------------------------------------------------
# ============================================================================
#  Mac：AWDL 智能守卫（串流时自动关，退出后自动恢复）
#
#  为什么需要它：
#    awdl0 是 AirDrop / 接力 / 通用剪贴板用的「直连无线电」。它会周期性把
#    Wi-Fi 电台切到"社交信道"约 100 毫秒 —— 这期间所有包全丢，而且是
#    「一次丢 4~13 个包的突发」（一帧视频才 4~7 个包，所以整帧废掉）。
#
#    实测数据（同一台机器、同样的 ping）：
#        开着 AWDL：抖动 max 63.7ms / mdev 12.7ms
#        关掉 AWDL：抖动 max  7.6ms / mdev  1.4ms
#    串流实际码率也从被自适应压到的 5 Mbps 恢复到满码率。
#
#    FEC 能补零散丢包，补不了这种突发丢包（实测把 FEC 加到 80% 也救不回来）。
#
#  逻辑：Moonlight 在串流 → 关 awdl0；没在串流 → 恢复。
#        这样平时 AirDrop 照常可用，只有打游戏那会儿让路。
#
#  安装：sudo bash scripts/mac/install-awdl-guard.sh
#  临时停用：sudo launchctl unload -w /Library/LaunchDaemons/com.local.awdl-guard.plist
# ============================================================================
set -uo pipefail

STATE_FILE="/var/run/awdl-guard.state"

is_awdl_up() {
    ifconfig awdl0 2>/dev/null | head -1 | grep -q "UP,"
}

moonlight_streaming() {
    # Moonlight 带 stream 参数运行 = 正在串流
    pgrep -f "MacOS/Moonlight stream" >/dev/null 2>&1
}

if moonlight_streaming; then
    # ---- 串流中：确保 AWDL 关着 ----
    if [ ! -f "$STATE_FILE" ]; then
        ifconfig awdl0 down 2>/dev/null || true
        touch "$STATE_FILE"
    elif is_awdl_up; then
        # macOS 偶尔会自己把它拉起来（比如后台想找 AirDrop 设备），持续按住
        ifconfig awdl0 down 2>/dev/null || true
    fi
else
    # ---- 没在串流：如果之前是我们关的，就恢复回去 ----
    if [ -f "$STATE_FILE" ]; then
        ifconfig awdl0 up 2>/dev/null || true
        rm -f "$STATE_FILE"
    fi
fi

exit 0
