#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  ENGLISH SUMMARY
#  Writes the Sunshine config. Three options are non-negotiable on a headless
#  box:  capture = x11       (the automatic path tries Wayland portal first,
#                             which always fails on a virtual display)
#        system_tray = false (no system tray exists, so Sunshine's main loop
#                             would exit immediately)
#        sunshine_name       (must match the name the Mac expects, or Moonlight
#                             reports "Found unexpected PC ... looking for ...")
#  Comments below are in Chinese / 下面的注释是中文。
# ---------------------------------------------------------------------------
# ============================================================================
#  ④ 写 Sunshine 配置
#
#  这几个选项不加会直接不能用，逐条说明：
#
#    capture = x11        ★ 必须。Sunshine 的自动探测会优先走 Wayland portal，
#                           虚拟屏上必然失败（报 Failed to create session）。
#                           注意 x11 抓屏方式 CPU 占用偏高，但无头场景没得选。
#    encoder = nvenc      NVIDIA 用 NVENC 硬编码；AMD 写 amdvce，Intel 写 quicksync
#    system_tray = false  ★ 必须。无头环境没有系统托盘，Sunshine 主循环会直接退出
#    sunshine_name        客户端（Moonlight）看到的主机名，要和 Mac 端填的一致
#    fec_percentage       前向纠错。Wi-Fi 有丢包时调高（40~60），有线 20~30
#
#  用法：bash scripts/40-configure-sunshine.sh
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
load_config

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
CONF_DIR="$TARGET_HOME/.config/sunshine"
CONF="$CONF_DIR/sunshine.conf"

info "配置摘要"
echo "    用户      : $TARGET_USER"
echo "    配置文件  : $CONF"
echo "    主机名    : $STREAM_HOST_NAME"
echo "    编码器    : ${SUNSHINE_ENCODER:-nvenc}"
echo "    前向纠错  : ${FEC_PERCENT:-40}%"
echo

mkdir -p "$CONF_DIR"

# 备份现有配置
if [ -f "$CONF" ]; then
    BAK="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONF" "$BAK"
    ok "已备份原配置 → $BAK"
fi

# 保留用户已有的自定义项，只覆盖我们管的这几条
TMP="$(mktemp)"
if [ -f "$CONF" ]; then
    grep -vE '^\s*(capture|encoder|system_tray|sunshine_name|fec_percentage|output_name)\s*=' "$CONF" > "$TMP" || true
fi

cat >> "$TMP" <<EOF

# ---- written by mac-linux-game-streaming below ----
# ---- 以下由 mac-linux-game-streaming 写入 ----
capture = x11
encoder = ${SUNSHINE_ENCODER:-nvenc}
system_tray = false
sunshine_name = $STREAM_HOST_NAME
fec_percentage = ${FEC_PERCENT:-40}
EOF

mv "$TMP" "$CONF"
chown "$TARGET_USER:$TARGET_USER" "$CONF" 2>/dev/null || true
ok "已写入"

echo "--- 生效的配置 ---"
grep -vE '^\s*#|^\s*$' "$CONF" | sed 's/^/    /'
echo

# 顺手检查 Sunshine 是否装了
if ! command -v sunshine >/dev/null 2>&1; then
    warn "没找到 sunshine 可执行文件。安装方式见 https://github.com/LizardByte/Sunshine"
    warn "（Ubuntu 可以从 GitHub Releases 下 .deb：sunshine-ubuntu-<版本>_amd64.deb）"
    exit 0
fi

info "重启 Sunshine 让配置生效"
UID_NUM="$(id -u "$TARGET_USER")"
sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$UID_NUM" systemctl --user restart sunshine 2>/dev/null \
    || warn "没能自动重启，手动执行：systemctl --user restart sunshine"
sleep 4

if pgrep -x sunshine >/dev/null 2>&1; then
    ok "Sunshine 正在运行"
else
    warn "Sunshine 没起来，看日志：$CONF_DIR/sunshine.log"
fi

echo
echo "    首次使用需要在 Sunshine 的 Web 界面设一次用户名密码："
echo "        https://<服务器地址>:${SUNSHINE_WEB_PORT:-47990}"
echo "    然后用 Moonlight 配对（同一局域网会自动发现主机）。"
echo
ok "完成。下一步：bash scripts/50-session-up.sh"
