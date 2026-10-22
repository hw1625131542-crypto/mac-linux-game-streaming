#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  ENGLISH SUMMARY
#  Switch between the two mutually exclusive modes of a single-GPU hybrid box:
#    --streaming : stop the desktop (gdm), start the headless Xorg + Sunshine
#    --desktop   : stop Sunshine + the headless Xorg, start the desktop again
#
#  Why mutually exclusive: Linux DRM allows exactly one master per GPU, so a
#  desktop session (PRIME) and a headless Xorg cannot both own the card.
#  See docs/hybrid-gpu.md (English) / docs/zh-CN/hybrid-gpu.md (中文).
#
#  Requires a narrow sudoers rule for starting/stopping gdm — see the doc.
#  Comments below are in Chinese / 下面的注释是中文。
# ---------------------------------------------------------------------------
# ============================================================================
#  60-mode-switch.sh —— 单显卡机器上「桌面 / 串流」两种模式互斥切换
#
#  为什么需要它：Linux 的 DRM 同一时刻只允许一张显卡有一个 master，
#  桌面会话（PRIME）和无头串流 Xorg 都要抢它，物理上不能共存。
#  详见 docs/hybrid-gpu.md
#
#  用法：
#      bash scripts/60-mode-switch.sh --streaming    # 切到串流
#      bash scripts/60-mode-switch.sh --desktop      # 切回桌面
#      bash scripts/60-mode-switch.sh --status       # 只看状态
#
#  前置：sudoers 里放行 gdm 的启停（见文档），否则会卡在密码提示
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config

MODE="${1:---status}"
SUNSHINE_UNIT="${SUNSHINE_UNIT:-app-dev.lizardbyte.app.Sunshine}"
XORG_UNIT="${XORG_UNIT:-mc-xorg}"
GAME_PATTERN="${GAME_PROC_PATTERN:-net.minecraft.client.main.Main}"

die_sudo() {
    err "需要 sudo 权限执行：$*"
    err "在 /etc/sudoers.d/ 里放行 systemctl 的 gdm / ${XORG_UNIT} 启停（见 docs/hybrid-gpu.md）"
    exit 1
}

status() {
    printf '  %-16s %s\n' "桌面 (gdm)"      "$(systemctl is-active gdm 2>/dev/null)"
    printf '  %-16s %s\n' "串流显示 (${XORG_UNIT})" "$(systemctl is-active "$XORG_UNIT" 2>/dev/null)"
    printf '  %-16s %s\n' "Sunshine"       "$(systemctl --user is-active "$SUNSHINE_UNIT" 2>/dev/null)"
    printf '  %-16s %s\n' "显示 socket"     "$(ls /tmp/.X11-unix/ 2>/dev/null | tr '\n' ' ')"
    printf '  %-16s %s\n' "当前 VT"         "$(cat /sys/class/tty/tty0/active 2>/dev/null)"
    pgrep -f "[${GAME_PATTERN:0:1}]${GAME_PATTERN:1}" >/dev/null 2>&1 \
        && printf '  %-16s %s\n' "游戏" "运行中" \
        || printf '  %-16s %s\n' "游戏" "未运行"
}

to_streaming() {
    info "切到串流模式"
    if systemctl is-active --quiet gdm 2>/dev/null; then
        info "停止登录界面（释放独显）"
        sudo -n systemctl stop gdm 2>/dev/null || die_sudo "systemctl stop gdm"
        sleep 2
    fi

    info "启动串流虚拟屏"
    sudo -n systemctl start "$XORG_UNIT" 2>/dev/null || die_sudo "systemctl start ${XORG_UNIT}"

    for _ in $(seq 1 20); do
        DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1 && break
        sleep 1
    done
    if ! DISPLAY="$DISPLAY_NUM" xdpyinfo >/dev/null 2>&1; then
        err "$DISPLAY_NUM 没起来，看 /var/log/${XORG_UNIT}.log"
        exit 1
    fi
    ok "虚拟屏就绪（$(DISPLAY="$DISPLAY_NUM" xdpyinfo | grep dimensions | awk '{print $2}')）"

    info "启动 Sunshine"
    systemctl --user start "$SUNSHINE_UNIT" 2>/dev/null
    sleep 2
    systemctl --user is-active --quiet "$SUNSHINE_UNIT" && ok "Sunshine 就绪" || { err "Sunshine 启动失败"; exit 1; }

    # 可选：断开后自动收尾
    if [ "${AUTO_RETURN:-0}" = "1" ]; then
        pkill -f '[6]1-auto-return.sh' 2>/dev/null
        setsid nohup "$HERE/61-auto-return.sh" >/dev/null 2>&1 < /dev/null &
        sleep 1
        pgrep -f '[6]1-auto-return.sh' >/dev/null 2>&1 \
            && ok "自动收尾守护已启动（断开 ${AUTO_RETURN_GRACE:-30} 秒后回桌面）" \
            || warn "自动收尾守护启动失败"
    fi
    ok "串流模式已就绪"
}

to_desktop() {
    info "切到桌面模式"
    info "停止 Sunshine"
    systemctl --user stop "$SUNSHINE_UNIT" 2>/dev/null

    info "停止串流虚拟屏"
    sudo -n systemctl stop "$XORG_UNIT" 2>/dev/null
    sleep 2

    info "恢复登录界面"
    if sudo -n systemctl start gdm 2>/dev/null; then
        sleep 3
        ok "桌面模式已就绪"
    else
        die_sudo "systemctl start gdm"
    fi
}

case "$MODE" in
    --streaming|streaming) to_streaming ;;
    --desktop|desktop)     to_desktop ;;
    --status|status)       status ;;
    *) echo "用法: $0 --streaming | --desktop | --status"; exit 2 ;;
esac
