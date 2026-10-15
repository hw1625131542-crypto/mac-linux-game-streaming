#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成一个自定义 EDID 文件（128 字节基础块），给无头 NVIDIA 输出用。

为什么需要它（两个原因，都很关键）：

  1) 没有 EDID 时，X 服务器的帧缓冲**读不回来**
     —— 无头输出（ConnectedMonitor 指到一个不存在的显示器）如果没有 EDID，
     X 能起来、xrandr 也显示正常分辨率，但 import / xwd / ffmpeg / Sunshine
     抓到的全是一张纯黑图（连把根窗口刷成纯红都抓不到）。
     给一个真 EDID 之后立刻正常。

  2) DPI 是由 EDID 里的**物理尺寸**反推的
     —— 尺寸填得不对，DPI 就会离谱（例如算成 191），
     于是 Chromium/CEF 一类的程序（游戏启动器就是）会把 UI 放大 2 倍、按钮全错位。
     本脚本按你指定的 DPI 反算物理尺寸，保证得到 96 DPI。

时序参数用系统的 `cvt` 工具算（x11-utils 包里有），也可以用 --modeline 直接给。

用法：
    # 从 config.env 读全部参数
    python3 make-edid.py --from-config scripts/config.env

    # 或者手动指定
    python3 make-edid.py --width 2560 --height 1600 --refresh 60 --dpi 96 \\
                         --out ~/game-stream-edid.bin

    # 自己提供 modeline（cvt 格式）
    python3 make-edid.py --modeline 'Modeline "2560x1600_60" 348.50 2560 2752 3032 3504 1600 1603 1613 1660 -hsync +vsync' \\
                         --width 2560 --height 1600 --out ~/edid.bin
"""

import argparse
import os
import re
import struct
import subprocess
import sys


# ---------------------------------------------------------------- 工具函数

def parse_config(path):
    """极简 config.env 解析：KEY="value" 或 KEY=value，忽略注释。"""
    cfg = {}
    if not os.path.exists(path):
        sys.exit("找不到配置文件：%s" % path)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            # 展开 $HOME（脚本里写的路径常常带它）
            val = val.replace("$HOME", os.path.expanduser("~"))
            cfg[key] = val
    return cfg


def run_cvt(width, height, refresh):
    """调用 cvt 生成标准 CVT 时序，返回 modeline 字符串。"""
    try:
        out = subprocess.run(["cvt", str(width), str(height), str(refresh)],
                             capture_output=True, text=True, timeout=10)
    except FileNotFoundError:
        sys.exit("找不到 `cvt` 命令。装一下：sudo apt install x11-utils\n"
                 "或者用 --modeline 手动提供时序。")
    line = None
    for l in out.stdout.splitlines():
        if l.strip().startswith("Modeline"):
            line = l.strip()
    if not line:
        sys.exit("cvt 没能算出 %dx%d@%d 的时序：\n%s" % (width, height, refresh, out.stdout + out.stderr))
    return line


def parse_modeline(line):
    """
    解析 cvt/xorg 的 Modeline 行，返回：
      (pclk_khz, h_active, h_front_porch, h_sync_width, h_back_porch,
                 v_active, v_front_porch, v_sync_width, v_back_porch,
                 hsync_negative, vsync_positive)

    cvt 输出形如：
      Modeline "2560x1664_60.00"  362.25  2560 2760 3032 3504  1664 1667 1677 1724 -hsync +vsync
      数字依次：像素时钟(MHz)、水平(显示宽 同步起点 同步终点 总宽)、竖直(同样四项)
    """
    # 先把引号里的名字（"2560x1664_60.00"）去掉，否则名字里的数字也会被抓出来
    stripped = re.sub(r'"[^"]*"', " ", line)
    nums = re.findall(r"\d*\.\d+|\d+", stripped)
    if len(nums) < 9:
        sys.exit("看不懂这个 modeline（数字少于 9 个）：%s" % line)

    pclk_mhz = float(nums[0])
    h = [int(float(x)) for x in nums[1:5]]
    v = [int(float(x)) for x in nums[5:9]]

    return (int(round(pclk_mhz * 1000)),
            h[0], h[1] - h[0], h[2] - h[1], h[3] - h[2],
            v[0], v[1] - v[0], v[2] - v[1], v[3] - v[2],
            "-hsync" in line, "+vsync" in line)


# ---------------------------------------------------------------- EDID 组装

def mfg_id(letters):
    """3 个字母 → EDID 的厂商 ID（每个字母 5 bit，大端）。"""
    letters = (letters.upper() + "XXX")[:3]
    v = ((ord(letters[0]) - 64) << 10) | ((ord(letters[1]) - 64) << 5) | (ord(letters[2]) - 64)
    return struct.pack(">H", v)


def detailed_timing(pclk_khz, h_active, h_fp, h_sp, h_bp,
                    v_active, v_fp, v_sp, v_bp,
                    h_mm, v_mm, hsync_neg=True, vsync_pos=True):
    """构造 18 字节的 Detailed Timing Descriptor。"""
    h_blank = h_fp + h_sp + h_bp
    v_blank = v_fp + v_sp + v_bp
    pclk_10khz = int(round(pclk_khz / 10.0))

    b = bytearray(18)
    b[0] = pclk_10khz & 0xFF
    b[1] = (pclk_10khz >> 8) & 0xFF
    b[2] = h_active & 0xFF
    b[3] = h_blank & 0xFF
    b[4] = ((h_active >> 8) << 4) | ((h_blank >> 8) & 0x0F)
    b[5] = v_active & 0xFF
    b[6] = v_blank & 0xFF
    b[7] = ((v_active >> 8) << 4) | ((v_blank >> 8) & 0x0F)
    b[8] = h_fp & 0xFF
    b[9] = h_sp & 0xFF
    b[10] = ((v_fp & 0x0F) << 4) | (v_sp & 0x0F)
    b[11] = (((h_fp >> 8) & 0x03) << 6) | (((h_sp >> 8) & 0x03) << 4) | \
            (((v_fp >> 4) & 0x03) << 2) | ((v_sp >> 4) & 0x03)
    b[12] = h_mm & 0xFF
    b[13] = v_mm & 0xFF
    b[14] = ((h_mm >> 8) << 4) | ((v_mm >> 8) & 0x0F)
    b[15] = 0   # 水平边框
    b[16] = 0   # 垂直边框

    # flags: bit4-3 = 11 (数字分离同步)，bit2 = vsync 正极性，bit1 = hsync 正极性
    flags = 0x18
    if vsync_pos:
        flags |= 0x04
    if not hsync_neg:
        flags |= 0x02
    b[17] = flags
    return bytes(b)


def range_limits(min_vr=48, max_vr=120, min_hr=30, max_hr=200, max_pclk_mhz=600):
    """显示器支持范围描述符：给足余量，免得驱动拒绝我们的自定义时序。"""
    return bytes([0x00, 0x00, 0x00, 0xFD, 0x00,
                  min_vr & 0xFF, max_vr & 0xFF, min_hr & 0xFF, max_hr & 0xFF,
                  min(255, max_pclk_mhz // 10), 0x00]) + bytes(7)


def name_descriptor(name):
    """显示器名字描述符（13 字节 ASCII，不足补空格/换行）。"""
    txt = (name.encode("ascii", "replace")[:13]).ljust(13, b" ")
    return bytes([0x00, 0x00, 0x00, 0xFC, 0x00]) + txt


def dummy_descriptor():
    return bytes([0x00, 0x00, 0x00, 0x10, 0x00]) + bytes(13)


def build_edid(dtd, width, height, dpi, name="HEADLESS"):
    """组装 128 字节的 EDID 基础块。"""
    # 由目标 DPI 反算物理尺寸（毫米）。DPI 错了 CEF 类程序会缩放错乱。
    h_mm = int(round(width / float(dpi) * 25.4))
    v_mm = int(round(height / float(dpi) * 25.4))

    e = bytearray(128)
    e[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    e[8:10] = mfg_id("LNX")                     # 厂商 ID（随便起）
    e[10:12] = struct.pack("<H", 0x0001)        # 产品代码
    e[12:16] = struct.pack("<I", 0x00000001)    # 序列号
    e[16] = 0x01                                # 生产周
    e[17] = 36                                  # 生产年（1990 + 36 = 2026）
    e[18] = 1                                   # EDID 版本 1
    e[19] = 3                                   # 修订 3
    e[20] = 0x80                                # 数字输入
    e[21] = min(255, (h_mm + 5) // 10)          # 最大水平尺寸（厘米）
    e[22] = min(255, (v_mm + 5) // 10)          # 最大垂直尺寸（厘米）
    e[23] = 120                                 # gamma 2.2
    e[24] = 0x0A                                # RGB + 首个 DTD 是首选时序
    e[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])  # 色度
    e[35:38] = bytes([0x00, 0x00, 0x00])        # 不声明任何「标准时序」
    e[38:54] = bytes([0x01, 0x01] * 8)          # 标准时序槽位全部留空
    e[54:72] = dtd                              # ★ 首选时序（我们要的分辨率）
    e[72:90] = range_limits()                   # 支持范围
    e[90:108] = name_descriptor(name)           # 显示器名字
    e[108:126] = dummy_descriptor()
    e[126] = 0                                  # 没有扩展块
    e[127] = (256 - (sum(e[0:127]) % 256)) % 256  # 校验和
    return bytes(e), h_mm, v_mm


def decode(edid):
    """把生成的 EDID 解回来，打印给人核对用。"""
    h_mm = edid[21] * 10
    v_mm = edid[22] * 10
    d = edid[54:72]
    pclk = (d[1] << 8 | d[0]) * 10          # kHz
    h_active = d[2] | ((d[4] >> 4) << 8)
    h_blank = d[3] | ((d[4] & 0x0F) << 8)
    v_active = d[5] | ((d[7] >> 4) << 8)
    v_blank = d[6] | ((d[7] & 0x0F) << 8)
    h_total = h_active + h_blank
    v_total = v_active + v_blank
    refresh = pclk * 1000.0 / (h_total * v_total)
    return {
        "resolution": "%dx%d" % (h_active, v_active),
        "pixel_clock_mhz": pclk / 1000.0,
        "refresh_hz": round(refresh, 2),
        "physical_mm": "%dx%d" % (h_mm, v_mm),
        "dpi": "%.0fx%.0f" % (h_active / (h_mm / 25.4), v_active / (v_mm / 25.4)),
        "checksum": "0x%02X" % edid[127],
    }


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description="生成无头输出用的自定义 EDID",
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__)
    ap.add_argument("--from-config", metavar="FILE",
                    help="从 config.env 读参数（推荐）")
    ap.add_argument("--width", type=int, help="水平像素")
    ap.add_argument("--height", type=int, help="垂直像素")
    ap.add_argument("--refresh", type=int, default=60, help="刷新率（默认 60）")
    ap.add_argument("--dpi", type=int, default=96, help="目标 DPI（默认 96）")
    ap.add_argument("--modeline", help="直接用这个 modeline，不调 cvt")
    ap.add_argument("--name", default="HEADLESS", help="显示器名字（13 字符内）")
    ap.add_argument("--out", help="输出文件路径（默认来自 --from-config 的 EDID_PATH）")
    args = ap.parse_args()

    cfg = parse_config(args.from_config) if args.from_config else {}

    width = args.width or int(cfg.get("STREAM_WIDTH", 0) or 0)
    height = args.height or int(cfg.get("STREAM_HEIGHT", 0) or 0)
    refresh = args.refresh or int(cfg.get("STREAM_REFRESH", 60) or 60)
    dpi = args.dpi or int(cfg.get("STREAM_DPI", 96) or 96)
    out = args.out or cfg.get("EDID_PATH") or os.path.expanduser("~/game-stream-edid.bin")

    if not width or not height:
        sys.exit("必须指定分辨率：--width/--height，或用 --from-config 提供 STREAM_WIDTH/HEIGHT")

    modeline = args.modeline or run_cvt(width, height, refresh)
    (pclk, ha, hfp, hsp, hbp, va, vfp, vsp, vbp, hsync_neg, vsync_pos) = parse_modeline(modeline)

    # 由 DPI 反算物理尺寸，再交给 DTD
    h_mm = int(round(ha / float(dpi) * 25.4))
    v_mm = int(round(va / float(dpi) * 25.4))

    dtd = detailed_timing(pclk, ha, hfp, hsp, hbp, va, vfp, vsp, vbp, h_mm, v_mm,
                          hsync_neg=hsync_neg, vsync_pos=vsync_pos)
    edid, h_mm2, v_mm2 = build_edid(dtd, ha, va, dpi, args.name)

    with open(out, "wb") as fh:
        fh.write(edid)

    info = decode(edid)
    print("已生成 EDID: %s（%d 字节）" % (out, len(edid)))
    print("  时序      : %s @ %s Hz（像素时钟 %s MHz）" %
          (info["resolution"], info["refresh_hz"], info["pixel_clock_mhz"]))
    print("  物理尺寸  : %s mm  →  DPI %s" % (info["physical_mm"], info["dpi"]))
    print("  校验和    : %s" % info["checksum"])
    print("  modeline  : %s" % modeline.strip())
    print()
    print("下一步：把这个路径填进 Xorg 配置的 CustomEDID，例如")
    print('  Option "CustomEDID" "DFP-0:%s"' % out)


if __name__ == "__main__":
    main()
