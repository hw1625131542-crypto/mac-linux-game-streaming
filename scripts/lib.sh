#!/usr/bin/env bash
# ============================================================================
#  公共函数库 —— 其它脚本都会 source 这个文件
#  不要直接运行它
# ============================================================================

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"

# ---------------------------------------------------------------- 载入配置
CONFIG_FILE="${CONFIG_FILE:-$LIB_DIR/config.env}"

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        if [ -f "$LIB_DIR/config.env.example" ]; then
            echo "⚠️  没找到 $CONFIG_FILE"
            echo "    先复制一份再改：cp scripts/config.env.example scripts/config.env"
            echo "    现在临时用 example 里的默认值继续（很可能连不上你的机器）"
            echo
            CONFIG_FILE="$LIB_DIR/config.env.example"
        else
            die "找不到配置文件 config.env / config.env.example"
        fi
    fi
    # shellcheck disable=SC1090
    set -a; . "$CONFIG_FILE"; set +a
}

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then
    C_RED=$'\033[1;31m'; C_GRN=$'\033[1;32m'; C_YEL=$'\033[1;33m'
    C_CYA=$'\033[1;36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYA=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_CYA" "$C_OFF" "$*"; }
ok()   { printf '    %s✓%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '    %s⚠%s  %s\n' "$C_YEL" "$C_OFF" "$*"; }
err()  { printf '    %s✗%s  %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- 小工具
require_root() {
    [ "$(id -u)" = "0" ] || die "需要 root 权限，请用 sudo 运行：sudo bash $0"
}

# 配置文件里的 $HOME 是在「服务器上」展开的，这里显式说明一下
require_config_value() {
    local key="$1" val="${!1:-}"
    [ -n "$val" ] || die "config.env 里的 $key 不能为空"
}

# 判断某个进程是否在跑（避免 pgrep 匹配到自己）
proc_running() {
    pgrep -f "[${1:0:1}]${1:1}" >/dev/null 2>&1
}

# 显示服务器是否可用
x_display_ready() {
    DISPLAY="$1" xdpyinfo >/dev/null 2>&1
}

# 等 X display 起来
wait_for_display() {
    local disp="$1" tries="${2:-30}"
    for _ in $(seq 1 "$tries"); do
        x_display_ready "$disp" && return 0
        sleep 0.5
    done
    return 1
}
