#!/usr/bin/env bash
# ============================================================================
#  ⑤ 一键拉起串流会话（幂等，可以反复跑）
#
#  依次确保：
#    1. headless Xorg 在跑（gamestream-xorg 服务）
#    2. Sunshine 在跑
#    3. 窗口管理器在跑（★ 关键：没有 WM 就没有焦点，键鼠进不了游戏窗口）
#    4. 游戏窗口无边框铺满（顺便解决"窗口模式看起来不是全屏"）
#    5. 游戏没开就开、并把它的窗口摆好
#    6. （可选）自动点一下启动器上的「开始游戏」
#
#  Mac 端的一键脚本会通过 SSH 调用这个脚本，所以它必须幂等：
#  重复调用不会开出第二个游戏实例。
#
#  用法：bash scripts/50-session-up.sh
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config

DISP="$DISPLAY_NUM"
export DISPLAY="$DISP"
[ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# ---------------------------------------------------------------- 0. Xorg
if x_display_ready "$DISP"; then
    ok "X display $DISP 已在运行"
else
    info "拉起 headless Xorg"
    sudo -n systemctl restart gamestream-xorg 2>/dev/null \
        || warn "需要 sudo：sudo systemctl restart gamestream-xorg"
    if wait_for_display "$DISP" 30; then
        ok "X display $DISP 就绪"
    else
        die "X display $DISP 起不来，看 /var/log/gamestream-xorg.log"
    fi
fi

# ---------------------------------------------------------------- 1. Sunshine
if pgrep -x sunshine >/dev/null 2>&1; then
    ok "Sunshine 已在运行"
else
    info "拉起 Sunshine"
    systemctl --user start sunshine 2>/dev/null || true
    sleep 3
    pgrep -x sunshine >/dev/null 2>&1 && ok "Sunshine 就绪" || warn "Sunshine 没起来"
fi

# ---------------------------------------------------------------- 2. 窗口管理器
if pgrep -x openbox >/dev/null 2>&1; then
    ok "openbox 已在运行"
else
    info "启动 openbox（没有它游戏窗口拿不到键鼠焦点）"
    setsid openbox >/tmp/openbox-gamestream.log 2>&1 < /dev/null &
    sleep 2
    pgrep -x openbox >/dev/null 2>&1 && ok "openbox 就绪" || warn "openbox 没起来，看 /tmp/openbox-gamestream.log"
fi

# ---------------------------------------------------------------- 3. 无边框规则
# 让游戏窗口没有标题栏、直接铺满 —— 这样"窗口模式"看起来也是全屏。
# 为什么不用真全屏：独占全屏在无头显示上常常会硬锁 30fps（见 docs/game-tuning.md）
RC="$HOME/.config/openbox/rc.xml"
if [ -f "$RC" ] && ! grep -q "gamestream-rule" "$RC" 2>/dev/null; then
    info "给游戏窗口加无边框规则"
    cp "$RC" "$RC.bak-$(date +%Y%m%d-%H%M%S)"
    python3 - "$RC" "${GAME_WINDOW_CLASS_2:-Minecraft}" <<'PY'
import re, sys
path, cls = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
rule = ('  <!-- gamestream-rule -->\n'
        '  <application class="%s*">\n'
        '    <decor>no</decor>\n'
        '    <maximized>true</maximized>\n'
        '    <position force="yes"><x>0</x><y>0</y></position>\n'
        '  </application>\n' % cls)
if "<applications>" in s:
    s = s.replace("<applications>", "<applications>\n" + rule, 1)
else:
    s = s.replace("</openbox_config>", "<applications>\n" + rule + "</applications>\n</openbox_config>")
open(path, "w", encoding="utf-8").write(s)
print("    规则已加入：class=%s*" % cls)
PY
    openbox --reconfigure 2>/dev/null || true
    ok "已应用"
else
    ok "无边框规则已存在（或没有 rc.xml，跳过）"
fi

# ---------------------------------------------------------------- 4. 游戏
GAME_PATTERN="${GAME_PROC_PATTERN:-net.minecraft.client.main.Main}"
game_running() { pgrep -f "[${GAME_PATTERN:0:1}]${GAME_PATTERN:1}" >/dev/null 2>&1; }

if game_running; then
    ok "游戏已在运行 —— 复用现有实例（避免开出第二个）"
else
    info "启动游戏启动器"
    cd "${GAME_DIR:-$HOME}" 2>/dev/null || true
    setsid "${GAME_LAUNCHER:-minecraft-launcher}" >/tmp/gamestream-launcher.log 2>&1 < /dev/null &
fi

# ---------------------------------------------------------------- 5. 摆窗口
pick_window() {
    local cls
    for cls in "${GAME_WINDOW_CLASS_2:-Minecraft}" "${GAME_WINDOW_CLASS:-minecraft-launcher}" Minecraft; do
        local w
        w="$(xdotool search --onlyvisible --class "$cls" 2>/dev/null | tail -1)"
        [ -n "$w" ] && { echo "$w"; return 0; }
    done
    xdotool search --onlyvisible --name "Minecraft" 2>/dev/null | tail -1
}

if ! game_running; then
    WID=""
    for _ in $(seq 1 60); do
        WID="$(pick_window)"
        [ -n "$WID" ] && break
        sleep 1
    done

    if [ -z "$WID" ]; then
        warn "没找到启动器窗口。连上串流后手动点一下桌面右键菜单里的启动项"
        exit 0
    fi

    # 屏幕实际尺寸（不一定等于 config 里的值，以 X 为准）
    read -r SW SH < <(xdotool getdisplaygeometry)
    xdotool windowmove "$WID" 0 0
    xdotool windowsize "$WID" "$SW" "$SH"
    xdotool windowactivate "$WID" 2>/dev/null || true
    ok "启动器窗口已铺满（${SW}x${SH}, wid=$WID）"

    # ------------------------------------------------------------ 6. 自动点击
    if [ "${AUTO_CLICK_X:-0}" != "0" ] && [ "${AUTO_CLICK_Y:-0}" != "0" ]; then
        info "自动点击「开始游戏」按钮（$AUTO_CLICK_X,$AUTO_CLICK_Y）"
        sleep 2
        for attempt in 1 2 3; do
            xdotool mousemove "$AUTO_CLICK_X" "$AUTO_CLICK_Y"
            sleep 0.4
            xdotool click 1
            for _ in $(seq 1 10); do
                game_running && { ok "游戏已启动 ✔"; exit 0; }
                sleep 1
            done
            warn "第 $attempt 次点击没生效"
        done
        warn "自动点击失败 —— 到串流画面里手动点一下那个按钮"
    else
        ok "未配置自动点击（AUTO_CLICK_X/Y=0），请在串流画面里手动点开始"
    fi
fi
