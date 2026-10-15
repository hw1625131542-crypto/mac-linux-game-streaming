#!/bin/bash
# ============================================================================
#  Mac：安装 AWDL 智能守卫（LaunchDaemon，每 3 秒检查一次）
#
#  用法：sudo bash scripts/mac/install-awdl-guard.sh
#
#  卸载：
#      sudo launchctl unload -w /Library/LaunchDaemons/com.local.awdl-guard.plist
#      sudo rm /Library/LaunchDaemons/com.local.awdl-guard.plist
#      sudo rm /usr/local/bin/awdl-guard.sh
#
#  注意：它会接管 awdl0 的开关。AirDrop/接力在「串流期间」会失效，
#        退出串流后自动恢复。
# ============================================================================
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "请用 sudo 运行：sudo bash $0" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.local.awdl-guard"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_PATH="/usr/local/bin/awdl-guard.sh"

echo "==> 1/4 安装守卫脚本 → $INSTALL_PATH"
mkdir -p /usr/local/bin
install -m 755 "$HERE/awdl-guard.sh" "$INSTALL_PATH"

echo "==> 2/4 写 LaunchDaemon（每 3 秒检查一次）"
# 说明：launchd 对 StartInterval 有 10 秒的最小节流，
#       所以实际响应时间通常在 3~10 秒之间 —— 无所谓，串流本身也要几秒才连上。
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_PATH}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3</integer>
</dict>
</plist>
PLIST_EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> 3/4 加载并立刻执行一次"
rm -f /var/run/awdl-guard.state
launchctl unload -w "$PLIST" 2>/dev/null || true
launchctl load -w "$PLIST"
"$INSTALL_PATH"

echo "==> 4/4 自检"
echo -n "    Moonlight 是否在串流: "
if pgrep -f "MacOS/Moonlight stream" >/dev/null 2>&1; then
    echo "是 → AWDL 现在应该是关的"
else
    echo "否 → AWDL 现在应该是开的"
fi
echo -n "    awdl0 状态: "
ifconfig awdl0 2>/dev/null | head -1 | sed 's/^awdl0: //'

cat <<'DONE'

────────────────────────────────────────────────────────────────
完成，之后全自动：

  · 双击串流脚本 → 几秒内 AWDL 自动关闭（Wi-Fi 空口干净，不卡顿）
  · 关掉 Moonlight → 几秒内 AWDL 自动恢复（AirDrop 可用）

想立刻验证：关掉 Moonlight 窗口，等 5 秒，AirDrop 就该能用了。
────────────────────────────────────────────────────────────────
DONE
