#!/usr/bin/env bash
# ============================================================================
#  ③ 修 /dev/uinput 权限（串流里鼠标键盘没反应的元凶）
#
#  症状：
#    串流窗口里鼠标不动、键盘没反应，Sunshine 日志里出现
#        Warning: Gamepad xxx is disabled due to gamepads.virtualhid-not-available
#        Warning: No gamepad input is available
#
#  原因：
#    Sunshine 是通过内核的 uinput/uhid 创建「虚拟鼠标 / 虚拟键盘 / 虚拟手柄」的。
#    /dev/uinput 默认权限是 root-only（或者靠 systemd-logind 给「活动会话」下的
#    用户临时挂一个 ACL）。一旦那个 ACL 被清掉，权限就退化成只有 root 能用，
#    Sunshine（以普通用户身份跑）就再也造不出虚拟输入设备了。
#
#  做法：
#    把 /dev/uinput 和 /dev/uhid 放开到 0666，并写成 udev 规则永久生效。
#    单用户的自用机器上没有安全顾虑；多人共用的机器请改成 0660 + 把用户加进 input 组。
#
#  用法：sudo bash scripts/30-fix-input-permissions.sh
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config
require_root

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$SERVER_USER")}"

info "1/4 当前权限"
ls -l /dev/uinput /dev/uhid 2>/dev/null | sed 's/^/    /' || warn "设备节点不存在（uinput 可能编进了内核，或模块没加载）"

info "2/4 立即修正权限 + 清掉可能残留的 ACL"
# ACL mask 变成 --- 时，ls 会显示成 crw-------，看起来像基权限被改了，其实是 ACL 作怪
setfacl -b /dev/uinput /dev/uhid 2>/dev/null || true
chmod 666 /dev/uinput 2>/dev/null || warn "改 /dev/uinput 权限失败"
chmod 666 /dev/uhid   2>/dev/null || true   # 手柄走这个
ls -l /dev/uinput /dev/uhid 2>/dev/null | sed 's/^/    /'

info "3/4 写 udev 规则（重启后依然有效）"
cat > /etc/udev/rules.d/85-gamestream-input.rules <<'RULE'
# 让游戏串流服务（以普通用户身份运行）能创建虚拟输入设备
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0666", OPTIONS+="static_node=uinput"
KERNEL=="uhid",   SUBSYSTEM=="misc", MODE="0666"
RULE
udevadm control --reload-rules
udevadm trigger --subsystem-match=misc 2>/dev/null || true
ok "已写入 /etc/udev/rules.d/85-gamestream-input.rules"

info "4/4 重启 Sunshine 并自检"
UID_NUM="$(id -u "$TARGET_USER")"
if systemctl --user --machine="$TARGET_USER@.host" is-active sunshine >/dev/null 2>&1; then
    systemctl --user --machine="$TARGET_USER@.host" restart sunshine || true
else
    # 大多数安装方式是用户级服务
    sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user restart sunshine 2>/dev/null \
        || warn "没能自动重启 Sunshine，手动重启一下：systemctl --user restart sunshine"
fi
sleep 5

if command -v sunshine >/dev/null 2>&1; then
    if grep -aq "virtualhid-not-available" "$TARGET_HOME/.config/sunshine/sunshine.log" 2>/dev/null; then
        LAST="$(grep -a 'virtualhid-not-available' "$TARGET_HOME/.config/sunshine/sunshine.log" | tail -1)"
        warn "日志里还有 virtualhid 报警（可能是重启前的旧记录）"
        echo "      $LAST"
    else
        ok "没有 virtualhid 报警了"
    fi
fi

echo
echo "    提示：光有权限还不够 —— 虚拟设备要等串流会话建立后才会创建。"
echo "          连上 Moonlight 之后验证："
echo "              grep -c libvirtualhid /proc/bus/input/devices     # 应该 > 0"
echo "              DISPLAY=$DISPLAY_NUM xinput list | grep libvirtualhid"
echo
ok "完成。下一步：bash scripts/40-configure-sunshine.sh"
