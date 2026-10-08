#!/bin/bash
#set -euo pipefail

# ================= 参数定义 =================
NO_CONFIRM=false
REPO_CONFIRM_ACTION=""
RCLONE_EXTRA_ARGS=()

# ================= 常量定义 =================
# 永久跳过标记文件名（不会被 cleanup 删除）
PERMANENT_IGNORE_FILE=".rclone_ignore"
# 临时跳过标记文件名
TEMP_IGNORE_FILE=".rclone_ignore_tmp"

# ================= 函数定义 =================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [--] [RCLONE_ARGS...]

Synchronize local files with remote storage using rclone bisync.
Git repositories are automatically packaged into bundles before sync.

Required configuration (in config/rclone.env):
  SYNC_ROOT     Local directory to sync
  REMOTE_NAME   Remote storage name (e.g., "remote:path")

Options:
  --no-confirm                  Skip the initial sync confirmation prompt
  --repo-confirm-action ACTION  Default action for repo-level prompts in bundle-repos.sh
                                Valid values: continue, skip, permanent, abort
  -h, --help                    Show this help message and exit

Arguments:
  RCLONE_ARGS   Additional arguments passed directly to rclone bisync
                (e.g., --dry-run, --resync, --verbose)

Examples:
  $(basename "$0")                  # Run bisync with default settings
  $(basename "$0") --dry-run        # Preview changes without syncing
  $(basename "$0") --resync         # Force full resync
  $(basename "$0") --no-confirm     # Skip the initial confirmation prompt
  $(basename "$0") --no-confirm --repo-confirm-action continue --dry-run
EOF
    exit 0
}

# ================= 初始化 =================

# 引用公共库
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOURCE_DIR/../lib/utils.sh"

# ================= 参数解析 =================

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --no-confirm)
            NO_CONFIRM=true
            shift
            ;;
        --repo-confirm-action)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "Option --repo-confirm-action requires a value: continue|skip|permanent|abort" >&2
                exit 1
            fi
            REPO_CONFIRM_ACTION="$2"
            shift 2
            ;;
        --repo-confirm-action=*)
            REPO_CONFIRM_ACTION="${1#*=}"
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                RCLONE_EXTRA_ARGS+=("$1")
                shift
            done
            break
            ;;
        *)
            RCLONE_EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

# ================= 加载配置 =================
load_config

if [[ -n "$REPO_CONFIRM_ACTION" ]] && ! is_valid_repo_confirm_action "$REPO_CONFIRM_ACTION"; then
    log_error "Invalid value for --repo-confirm-action: $REPO_CONFIRM_ACTION"
    log_error "Expected one of: continue, skip, permanent, abort"
    exit 1
fi

# 检查必需的配置变量（必须在 config/rclone.env 中定义）
[[ -n "${SYNC_ROOT:-}" ]] || { log_error "SYNC_ROOT is not set or empty. Please define it in config/rclone.env" && exit 1; }
[[ -n "${REMOTE_NAME:-}" ]] || { log_error "REMOTE_NAME is not set or empty. Please define it in config/rclone.env" && exit 1; }

# 展开 ~ 为 home 目录，并移除尾部斜杠
SYNC_ROOT="${SYNC_ROOT/#\~/$HOME}"
SYNC_ROOT="${SYNC_ROOT%/}"

# 检查依赖
check_dependency "rclone"

# ================= 清理函数 =================

cleanup() {
    # 无论脚本成功还是失败，都清理掉所有的 .rclone_ignore_tmp 文件
    if [[ -d "$SYNC_ROOT" ]]; then
        find -H "$SYNC_ROOT" -name "$TEMP_IGNORE_FILE" -delete 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ================= 主流程 =================

log_header "启动 Rclone Bisync Suite"
log_info "同步根目录: $SYNC_ROOT"
log_info "远程仓库:   $REMOTE_NAME"
if [[ ${#RCLONE_EXTRA_ARGS[@]} -gt 0 ]]; then
    log_info "额外参数:   ${RCLONE_EXTRA_ARGS[*]}"
fi
if [[ "$NO_CONFIRM" == true ]]; then
    log_info "开始确认:   已跳过 (--no-confirm)"
fi
if [[ -n "$REPO_CONFIRM_ACTION" ]]; then
    log_info "仓库级确认: 默认动作 $REPO_CONFIRM_ACTION"
fi

# --- 初始确认 ---
if [[ "$NO_CONFIRM" != true ]]; then
    echo
    read -r -p "是否确认开始同步操作？(y/n): " confirm_sync
    case "$confirm_sync" in
        y|Y )
            log_info "已确认，开始同步。"
            ;;
        * )
            log_warn "取消同步。"
            exit 0
            ;;
    esac
fi

# --- 阶段 1: 扫描并打包 Git Repos ---
# (bundle-repos.sh 内部会打印自己的 header)

# 调用 bundle-repos.sh，传入 --no-confirm（因为已经确认过）
bundle_cmd=("$SOURCE_DIR/bundle-repos.sh" --no-confirm)
if [[ -n "$REPO_CONFIRM_ACTION" ]]; then
    bundle_cmd+=(--repo-confirm-action "$REPO_CONFIRM_ACTION")
fi

if "${bundle_cmd[@]}"; then
    :
else
    exit_code=$?
    if [[ $exit_code -eq 2 ]]; then
        log_warn "用户取消操作"
    else
        log_error "打包过程出错 (exit code: $exit_code)"
    fi
    exit $exit_code
fi

# --- 阶段 2: 执行 Rclone Bisync ---
log_header "阶段 2: 执行云端同步"

# 构建 rclone 命令参数数组
RCLONE_CMD=(
    rclone bisync
    "$SYNC_ROOT"
    "$REMOTE_NAME"
    --create-empty-src-dirs
    --compare size,modtime,checksum
    --resilient -vP
    --fix-case
    --modify-window 1s
    --filters-file "$FILTER_FILE"
    --exclude-if-present "$TEMP_IGNORE_FILE"
    --exclude-if-present "$PERMANENT_IGNORE_FILE"
)

# 添加额外参数
if [[ ${#RCLONE_EXTRA_ARGS[@]} -gt 0 ]]; then
    RCLONE_CMD+=("${RCLONE_EXTRA_ARGS[@]}")
fi

# 添加配置中的额外选项
if [[ -n "${RCLONE_OPTS:-}" ]]; then
    # shellcheck disable=SC2206
    RCLONE_CMD+=($RCLONE_OPTS)
fi

log_info "执行命令: ${RCLONE_CMD[*]}"
"${RCLONE_CMD[@]}"

log_header "同步流程成功结束"
