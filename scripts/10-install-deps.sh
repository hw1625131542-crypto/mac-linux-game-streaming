#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  ENGLISH SUMMARY
#  Installs the dependencies this approach relies on (x11-utils for `cvt`,
#  xdotool, mesa-utils for glxinfo/glxgears, openbox, imagemagick), then checks
#  that an NVIDIA driver and Xorg's nvidia driver module are actually present.
#  Comments below are in Chinese / 下面的注释是中文。
# ---------------------------------------------------------------------------
# ============================================================================
#  ① 装依赖
#
#  需要的东西不多：
#    · x11-utils   → 提供 cvt（算时序）、xdpyinfo、xrandr、xinput、xwininfo
#    · x11-xserver-utils → xsetroot 等
#    · xdotool     → 摆放窗口、自动点击
#    · mesa-utils  → glxinfo / glxgears（测帧率用，强烈建议留着）
#    · openbox     → 无头环境里的窗口管理器（不然游戏窗口没有焦点，键鼠收不到）
#    · imagemagick → import（截屏验证）
#
#  用法：bash scripts/10-install-deps.sh
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config

info "1/2 安装依赖（需要 sudo 的话会提示）"
SUDO=""
[ "$(id -u)" != "0" ] && SUDO="sudo"

$SUDO apt-get update -qq
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq \
    x11-utils x11-xserver-utils xdotool mesa-utils \
    openbox imagemagick curl jq python3
ok "依赖装完"

info "2/2 环境自检"
for cmd in Xorg cvt xdotool xdpyinfo openbox import python3; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd → $(command -v "$cmd")"
    else
        warn "$cmd 缺失"
    fi
done

# NVIDIA 驱动检查（这是整套方案的前提）
if command -v nvidia-smi >/dev/null 2>&1; then
    ok "NVIDIA 驱动：$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -1)"
    if [ ! -f /usr/lib/xorg/modules/drivers/nvidia_drv.so ] && \
       [ ! -f /usr/lib/x86_64-linux-gnu/nvidia/xorg/nvidia_drv.so ]; then
        warn "找不到 nvidia_drv.so（Xorg 的 NVIDIA 驱动模块）"
        warn "装一下：sudo apt install xserver-xorg-video-nvidia-<你的驱动大版本>"
    else
        ok "Xorg 的 NVIDIA 驱动模块已就位"
    fi
else
    warn "没检测到 nvidia-smi。本方案针对 NVIDIA 显卡；"
    warn "AMD/Intel 也能用（把 Xorg 配置里的 Driver 换成 modesetting/amdgpu），但没实测过。"
fi

echo
ok "完成。下一步：python3 scripts/make-edid.py --from-config scripts/config.env"
