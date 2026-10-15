#!/bin/bash
# ============================================================================
#  Mac 端一键串流（Finder 里双击运行）
#
#  做的事：
#    1. SSH 到服务器，让它把「虚拟屏 + Sunshine + 窗口管理器 + 游戏」准备好
#    2. 用正确的参数打开 Moonlight 连上去
#
#  配置来源：同仓库的 scripts/config.env（和服务器端共用一份）
#  想改 IP / 分辨率 / 码率，改那个文件就行，不用动这个脚本。
#
#  用法：Finder 双击，或命令行 bash start-stream.command [--bitrate 20000]
# ============================================================================

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$HERE/../config.env}"
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="$HERE/../config.env.example"

# ---------- 默认值（config.env 里没写的话就用这些）----------
SERVER_HOST="192.168.1.50"
SERVER_USER="player"
SERVER_SSH_PORT="22"
SERVER_HOST_FALLBACK=""
STREAM_HOST_NAME="GAME-PC"
STREAM_WIDTH="2560"
STREAM_HEIGHT="1600"
STREAM_FPS="60"
BITRATE_KBPS="35000"
MOONLIGHT_APP="/Applications/Moonlight.app"

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CONFIG_FILE"; set +a
fi

# ---------- 命令行覆盖 ----------
while [ $# -gt 0 ]; do
    case "$1" in
        --bitrate) BITRATE_KBPS="$2"; shift 2 ;;
        --res)     STREAM_WIDTH="${2%x*}"; STREAM_HEIGHT="${2#*x}"; shift 2 ;;
        --fps)     STREAM_FPS="$2"; shift 2 ;;
        --host)    STREAM_HOST_NAME="$2"; shift 2 ;;
        *) shift ;;
    esac
done

BIN="$MOONLIGHT_APP/Contents/MacOS/Moonlight"
RES="${STREAM_WIDTH}x${STREAM_HEIGHT}"

if [ ! -x "$BIN" ]; then
    echo "❌ 找不到 Moonlight：$MOONLIGHT_APP"
    echo "   去 https://moonlight-stream.org/ 装一个，或在 config.env 里改 MOONLIGHT_APP"
    read -n 1 -s -r -p "按任意键退出…"
    exit 1
fi

echo "🎮 游戏串流启动中…"
echo

# ---------- 1. 让服务器把画面准备好 ----------
echo "① 让服务器准备画面（虚拟屏 + Sunshine + 游戏）"
READY=0
for HOST in "$SERVER_HOST" ${SERVER_HOST_FALLBACK:+"$SERVER_HOST_FALLBACK"}; do
    [ -n "$HOST" ] || continue
    printf '   → %s … ' "$HOST"
    if OUT=$(ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
                 -p "$SERVER_SSH_PORT" "$SERVER_USER@$HOST" \
                 'bash ~/mac-linux-game-streaming/scripts/50-session-up.sh 2>&1 || bash ~/50-session-up.sh 2>&1' 2>&1); then
        echo "OK"
        echo "$OUT" | sed 's/^/     /'
        READY=1
        break
    fi
    echo "连不上"
done

if [ "$READY" = "0" ]; then
    echo "   ⚠️  服务器没连上（没开机 / 不在同一网络 / SSH 端口不对）"
    echo "       仍然尝试直接串流…"
fi
echo

# ---------- 2. 打开 Moonlight ----------
echo "② 连接 $STREAM_HOST_NAME   分辨率 $RES @ ${STREAM_FPS}fps   码率 ${BITRATE_KBPS} Kbps"
echo

# Moonlight 只允许单实例
pkill -x Moonlight 2>/dev/null
sleep 2

# ★ 必须显式指定 Qt 插件路径，否则报
#   module "QtQuick.Controls" plugin "qtquickcontrols2plugin" not found
export QT_PLUGIN_PATH="$MOONLIGHT_APP/Contents/PlugIns"
export QML2_IMPORT_PATH="$MOONLIGHT_APP/Contents/Resources/qml"

cat <<'EOF'
────────────────────────────────────────────────────────────────
参数说明（都在 config.env 里改）：
  --absolute-mouse   远程桌面必须用绝对鼠标。不加的话光标一点进窗口
                     就会被隐藏并锁住，看着像"鼠标消失了、还移不出来"
  --vsync            不加会画面撕裂
────────────────────────────────────────────────────────────────
EOF
echo

exec "$BIN" stream "$STREAM_HOST_NAME" "Desktop" \
    --resolution "$RES" \
    --fps "$STREAM_FPS" \
    --bitrate "$BITRATE_KBPS" \
    --display-mode windowed \
    --absolute-mouse \
    --vsync
