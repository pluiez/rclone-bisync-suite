#!/usr/bin/env bash
# =========================================================
# log.sh — Emoji + 仅前缀上色 + 刷新 + 主题/色深自适应
# 主题：LOG_THEME=dark|light|mono   (默认 dark)
# 颜色：优先 256 色(38;5;N)，不支持时回退到 16 色
# 开关：NO_COLOR=1 关闭着色；仅 TTY 着色
# =========================================================

# ---------- Emoji（不变） ----------
declare -A LEVEL2EMOJI=(
  [INFO]="💡"
  [WARNING]="⚠️"
  [ERROR]="❌"
  [SUCCESS]="✅"
  [START]="🚀"
  [IN_PROGRESS]="🏃"
  [DONE]="🎉"
)

# ---------- 主题定义（语义一致 + 高对比） ----------
# 语义说明：
#   INFO        —— 提示/说明（青色系，清晰、理性）
#   WARNING     —— 警告（琥珀/黄，强可见且不刺眼）
#   ERROR       —— 错误（红色，最高优先级）
#   SUCCESS     —— 成功（绿色，完成/通过）
#   START       —— 启动（洋红/紫，强调“开始”）
#   IN_PROGRESS —— 进行中（蓝色，稳定、冷静）
#   DONE        —— 结束/阶段完成（靛紫，区别于 SUCCESS）
#
# 说明：dark 主题使用更“明亮”的前景色；light 主题使用“偏深”的色值以适配浅底；
# mono 主题不着色，但会保留粗体，适合极简或日志采集系统。
#
# 256 色代码（前景：\033[38;5;Nm）
declare -A THEME_DARK_256=(
  [INFO]=45         # bright cyan
  [WARNING]=220     # amber yellow
  [ERROR]=203       # bright red
  [SUCCESS]=46      # bright green
  [START]=213       # bright magenta
  [IN_PROGRESS]=39  # bright blue
  [DONE]=141        # bright violet
)
declare -A THEME_LIGHT_256=(
  [INFO]=24         # deep cyan
  [WARNING]=136     # dark amber
  [ERROR]=124       # deep red
  [SUCCESS]=28      # deep green
  [START]=91        # deep magenta
  [IN_PROGRESS]=18  # navy blue
  [DONE]=57         # indigo
)

# 16 色回退（粗体亮色系）
declare -A THEME_DARK_16=(
  [INFO]=$'\033[1;36m'      # bright cyan
  [WARNING]=$'\033[1;33m'   # bright yellow
  [ERROR]=$'\033[1;31m'     # bright red
  [SUCCESS]=$'\033[1;32m'   # bright green
  [START]=$'\033[1;35m'     # bright magenta
  [IN_PROGRESS]=$'\033[1;34m' # bright blue
  [DONE]=$'\033[1;35m'      # bright magenta (区分于 SUCCESS 的绿)
)
declare -A THEME_LIGHT_16=(
  [INFO]=$'\033[36m'        # cyan (不加粗，适配浅底)
  [WARNING]=$'\033[33m'     # yellow
  [ERROR]=$'\033[31m'       # red
  [SUCCESS]=$'\033[32m'     # green
  [START]=$'\033[35m'       # magenta
  [IN_PROGRESS]=$'\033[34m' # blue
  [DONE]=$'\033[35m'        # magenta
)

COLOR_RESET=$'\033[0m'
BOLD=$'\033[1m'

__log_supports_256() {
  # 支持 256 色：tput colors >= 256 且 TERM 不是 dumb
  if command -v tput >/dev/null 2>&1; then
    local n; n=$(tput colors 2>/dev/null || echo 0)
    [[ -n "$n" && "$n" -ge 256 && "${TERM:-}" != "dumb" ]]
  else
    return 1
  fi
}

__log_should_color() { [[ -t 2 && -z "${NO_COLOR:-}" ]]; }

# 规范化到 7 个 level
__normalize_level() {
  local lvl="${1^^}"
  case "$lvl" in
    WARN) echo WARNING ;;
    OK|SUCCESS) echo SUCCESS ;;
    RUNNING|INPROGRESS|IN_PROGRESS) echo IN_PROGRESS ;;
    START|STARTING) echo START ;;
    DONE|FINISH|FINISHED) echo DONE ;;
    INFO|WARNING|ERROR) echo "$lvl" ;;
    *) echo INFO ;;
  esac
}

# 根据主题 & 色深生成前缀颜色转义
__prefix_color_for() {
  local lvl="$1"
  local theme="${LOG_THEME:-dark}"
  local use256=false
  local code="" esc=""

  if __log_should_color; then
    if __log_supports_256; then
      use256=true
    fi
  else
    echo "" ; return
  fi

  if $use256; then
    if [[ "$theme" == "light" ]]; then
      code="${THEME_LIGHT_256[$lvl]}"
    elif [[ "$theme" == "mono" ]]; then
      echo "$BOLD"; return
    else
      code="${THEME_DARK_256[$lvl]}"
    fi
    # 256 色 + 加粗，保证高可读性
    if [[ -n "$code" ]]; then
      esc=$'\033[1m'$(printf '\033[38;5;%sm' "$code")
      printf "%s" "$esc"
      return
    fi
  fi

  # 16 色回退
  if [[ "$theme" == "light" ]]; then
    esc="${THEME_LIGHT_16[$lvl]}"
  elif [[ "$theme" == "mono" ]]; then
    esc="$BOLD"
  else
    esc="${THEME_DARK_16[$lvl]}"
  fi
  printf "%s" "${esc:-$BOLD}"
}

# ---------------- 主日志函数 ----------------
log() {
  local refresh="${refresh:-false}"
  local lvl="$(__normalize_level "${level:-INFO}")"

  local emoji="${LEVEL2EMOJI[$lvl]:-❔}"
  local ts rk prefix color reset
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  
  # 仅在 RANK 不为 ? 时显示 (rank-N)
  if [[ "${RANK:-?}" != "?" ]]; then
    rk=" (rank-$RANK)"
  else
    rk=""
  fi

  # 仅给 prefix 上色，消息体不着色
  printf -v prefix "[%s]%s [%s %s]:" "$ts" "$rk" "$emoji" "$lvl"

  if __log_should_color; then
    color="$(__prefix_color_for "$lvl")"
    reset="$COLOR_RESET"
  else
    color=""; reset=""
  fi

  if [[ "$refresh" == true ]]; then
    if [[ -n "$color" ]]; then
      printf "\r%s%s%s %s" "$color" "$prefix" "$reset" "$*" >&2
    else
      printf "\r%s %s" "$prefix" "$*" >&2
    fi
  else
    if [[ -n "$color" ]]; then
      printf "%s%s%s %s\n" "$color" "$prefix" "$reset" "$*" >&2
    else
      printf "%s %s\n" "$prefix" "$*" >&2
    fi
  fi
}

log_newline() { printf "\n" >&2; }

# ---------------- 便捷函数（7 个） ----------------
log_info()         { level=INFO         log "$@"; }
log_warning()      { level=WARNING      log "$@"; }
log_error()        { level=ERROR        log "$@"; }
log_success()      { level=SUCCESS      log "$@"; }
log_start()        { level=START        log "$@"; }
log_in_progress()  { level=IN_PROGRESS  log "$@"; }
log_done()         { level=DONE         log "$@"; }

# ---------------- 兼容性别名 ----------------
# log_warn 作为 log_warning 的别名，保持向后兼容
log_warn() { log_warning "$@"; }

# ---------------- 标题/分隔线函数 ----------------
log_header() {
  local color reset
  local header_width=60
  local text="$*"
  local text_len=${#text}
  local padding=$(( (header_width - text_len) / 2 ))
  local separator
  printf -v separator '%*s' "$header_width" ''
  separator="${separator// /=}"
  
  if __log_should_color; then
    color="$(__prefix_color_for "IN_PROGRESS")"
    reset="$COLOR_RESET"
  else
    color=""; reset=""
  fi
  printf "\n%s%s%s\n" "$color" "$separator" "$reset" >&2
  printf "%s%*s%s%s\n" "$color" "$padding" "" "$text" "$reset" >&2
  printf "%s%s%s\n" "$color" "$separator" "$reset" >&2
}

# 可选导出（避免 set -u 冒泡）
export -f log log_newline \
  log_info log_warning log_warn log_error log_success \
  log_start log_in_progress log_done log_header 2>/dev/null || true




