#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  ENGLISH SUMMARY
#  Watches Sunshine's log and, after the streaming client disconnects (plus a
#  grace period so a brief hiccup doesn't kill the session), closes the game
#  cleanly, closes the launcher, and switches back to the desktop mode.
#
#  Started in the background by 60-mode-switch.sh --streaming when AUTO_RETURN=1.
#  Read docs/hybrid-gpu.md for the two traps this has to avoid:
#    · close windows with WM_DELETE / SIGTERM — never kill -9
#    · only act while the headless Xorg is active
#  Comments below are in Chinese / 下面的注释是中文。
# ---------------------------------------------------------------------------
# ============================================================================
#  61-auto-return.sh —— 串流结束后自动收尾
#
#  流程：等客户端连上 → 等断开 → 宽限期 → 干净关游戏 → 关启动器 → 切回桌面
#
#  为什么必须先关游戏：游戏也占着独显，不关掉桌面拿不到显卡，起不来。
#  为什么不能 kill -9：启动器在写凭据时被杀会损坏登录信息（见 docs/maintenance.md）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config

SUNSHINE_LOG="${SUNSHINE_LOG:-$HOME/.config/sunshine/sunshine.log}"
SUNSHINE_UNIT="${SUNSHINE_UNIT:-app-dev.lizardbyte.app.Sunshine}"
XORG_UNIT="${XORG_UNIT:-mc-xorg}"
GAME_PATTERN="${GAME_PROC_PATTERN:-net.minecraft.client.main.Main}"
GRACE="${AUTO_RETURN_GRACE:-30}"
STATE_FILE="${TMPDIR:-/tmp}/auto-return.state"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "${AUTO_RETURN_LOG:-$HOME/auto-return.log}"; }

# 数日志里的连接事件。注意：grep -c 没匹配时也会输出 0，退出码非零，
# 所以用 || true，千万不要用 || echo 0（会得到 "0\n0" 把数值比较搞坏）
count() { grep -ac "$1" "$SUNSHINE_LOG" 2>/dev/null || true; }

# 只在串流模式下工作
systemctl is-active --quiet "$XORG_UNIT" || exit 0

BASE=$(count "CLIENT CONNECTED")

# 1. 等客户端连上（最多 20 分钟）
for _ in $(seq 1 240); do
    [ "$(count 'CLIENT CONNECTED')" -gt "$BASE" ] && break
    sleep 5
done
[ "$(count 'CLIENT CONNECTED')" -le "$BASE" ] && { log "等待超时，退出"; exit 0; }
log "客户端已连接"

# 2. 等断开（连接数 == 断开数）
while :; do
    [ "$(count 'CLIENT CONNECTED')" -le "$(count 'CLIENT DISCONNECTED')" ] && break
    sleep 5
done
log "客户端断开，进入 ${GRACE} 秒宽限期"

# 3. 宽限期内重连就继续等
sleep "$GRACE"
if [ "$(count 'CLIENT CONNECTED')" -gt "$(count 'CLIENT DISCONNECTED')" ]; then
    log "宽限期内重连，重新开始守护"
    exec "$0"
fi

# 4. 收尾
log "开始收尾"
systemctl is-active --quiet "$XORG_UNIT" || { log "已不在串流模式，退出"; exit 0; }
systemctl --user is-active --quiet "$SUNSHINE_UNIT" 2>/dev/null || log "Sunshine 已经不在运行"

# 4a. 干净关闭游戏（WM_DELETE → 游戏正常存档退出）
GW=$(xdotool search --classname "com.mojang.minecraft" 2>/dev/null | head -1)
if [ -n "$GW" ]; then
    log "关闭游戏窗口 $GW"
    xdotool windowclose "$GW" 2>/dev/null
    for _ in $(seq 1 20); do
        pgrep -f "[${GAME_PATTERN:0:1}]${GAME_PATTERN:1}" >/dev/null 2>&1 || break
        sleep 2
    done
fi
pgrep -f "[${GAME_PATTERN:0:1}]${GAME_PATTERN:1}" >/dev/null 2>&1 \
    && log "⚠ 游戏没退（可能在存档）" || log "✓ 游戏已退出"

# 4b. 关闭启动器（Electron 常常不理 WM_DELETE，用 SIGTERM，绝不用 -9）
LAUNCHER_PATTERN="${GAME_WINDOW_CLASS:-minecraft-launcher}"
if pgrep -f "[${LAUNCHER_PATTERN:0:1}]${LAUNCHER_PATTERN:1}" >/dev/null 2>&1; then
    log "关闭启动器"
    pkill -TERM -f "[${LAUNCHER_PATTERN:0:1}]${LAUNCHER_PATTERN:1}" 2>/dev/null
    sleep 5
fi
pgrep -f "[${LAUNCHER_PATTERN:0:1}]${LAUNCHER_PATTERN:1}" >/dev/null 2>&1 \
    && log "⚠ 启动器还在" || log "✓ 启动器已退出"

# 4c. 切回桌面
log "切换回桌面模式"
bash "$HERE/60-mode-switch.sh" --desktop >> "${AUTO_RETURN_LOG:-$HOME/auto-return.log}" 2>&1
log "✓ 收尾完成"
