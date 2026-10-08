#!/bin/bash
#set -euo pipefail

# ================= 常量定义 =================
# 目录大小增长阈值（百分比）
SIZE_INCREASE_THRESHOLD=10
# 首次同步时的大小阈值
FIRST_SYNC_SIZE_THRESHOLD=$(numfmt --from=iec "20M")
# 永久跳过标记文件名
PERMANENT_IGNORE_FILE=".rclone_ignore"
# 临时跳过标记文件名
TEMP_IGNORE_FILE=".rclone_ignore_tmp"

# ================= 选项解析 =================
DRY_RUN=false
NO_CONFIRM=false
REPO_CONFIRM_ACTION=""
QUIET=false
DEBUG=false
SYNC_ROOT_ARG=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [SYNC_ROOT]

Scan and bundle Git repositories for cloud synchronization.

Arguments:
  SYNC_ROOT       Local directory to scan (default: from config/rclone.env)

Options:
  --dry-run       Only check status, don't create or modify any files
  --no-confirm    Skip initial confirmation prompt
  --repo-confirm-action ACTION
                  Default action for repo-level prompts
                  Valid values: continue, skip, permanent, abort
  -q, --quiet     Quiet mode, reduce log output
  --debug         Show timing information for performance debugging
  -h, --help      Show this help message and exit

Exit Codes:
  0  Success
  1  Parameter or configuration error
  2  User cancelled

Examples:
  $(basename "$0")                    # Run with default config
  $(basename "$0") --dry-run          # Preview what would be done
  $(basename "$0") ~/my-sync-root     # Use custom sync root
  $(basename "$0") --repo-confirm-action continue
  $(basename "$0") --no-confirm --repo-confirm-action abort
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        --dry-run)
            DRY_RUN=true
            shift
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
        -q|--quiet)
            QUIET=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            SYNC_ROOT_ARG="$1"
            shift
            ;;
    esac
done

# ================= 初始化 =================

# 引用公共库
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOURCE_DIR/../lib/utils.sh"
BUNDLE_HELPER_SCRIPT="$SOURCE_DIR/create-repo-bundle.sh"

# ================= 加载配置 =================
load_config

if [[ -n "$REPO_CONFIRM_ACTION" ]] && ! is_valid_repo_confirm_action "$REPO_CONFIRM_ACTION"; then
    log_error "Invalid value for --repo-confirm-action: $REPO_CONFIRM_ACTION"
    log_error "Expected one of: continue, skip, permanent, abort"
    exit 1
fi

# 使用命令行参数覆盖配置
if [[ -n "$SYNC_ROOT_ARG" ]]; then
    SYNC_ROOT="$SYNC_ROOT_ARG"
fi

# 检查必需的配置变量
[[ -n "${SYNC_ROOT:-}" ]] || { log_error "SYNC_ROOT is not set. Please define it in config/rclone.env or pass as argument" >&2 && exit 1; }

# 展开 ~ 为 home 目录，并移除尾部斜杠
SYNC_ROOT="${SYNC_ROOT/#\~/$HOME}"
SYNC_ROOT="${SYNC_ROOT%/}"

# 检查 SYNC_ROOT 存在
[[ -d "$SYNC_ROOT" ]] || { log_error "SYNC_ROOT does not exist: $SYNC_ROOT" >&2 && exit 1; }

# 检查依赖
check_dependency "tar"
check_dependency "git"
[[ -f "$BUNDLE_HELPER_SCRIPT" ]] || { log_error "Bundle helper script not found: $BUNDLE_HELPER_SCRIPT" >&2 && exit 1; }

# ================= 内部变量 =================

BUNDLE_DIR="$SYNC_ROOT/git_bundles"
CURRENT_TIMESTAMP=$(date -Iseconds)

# 统计变量
declare -a REPOS_NEW=()
declare -a REPOS_UPDATED=()
declare -a REPOS_UP_TO_DATE=()
declare -a REPOS_BEHIND=()
declare -a REPOS_SKIPPED=()

# 存储详细信息用于最终报告
declare -A REPO_VERSION=()
declare -A REPO_TIMESTAMP=()
declare -A REPO_BEHIND_INFO=()

# ================= 工具函数 =================

# 日志函数（输出到 stderr）
log_info_stderr() {
    if [[ "$QUIET" != true ]]; then
        log_info "$1" >&2
    fi
}

log_warn_stderr() {
    log_warn "$1" >&2
}

log_error_stderr() {
    log_error "$1" >&2
}

log_header_stderr() {
    if [[ "$QUIET" != true ]]; then
        log_header "$1" >&2
    fi
}

# 获取 repo 的 bundle 目录路径
get_repo_bundle_dir() {
    local relative_path="$1"
    echo "$BUNDLE_DIR/$relative_path"
}

# 获取 repo 的 metadata 目录路径
get_repo_metadata_dir() {
    local relative_path="$1"
    echo "$BUNDLE_DIR/$relative_path/metadata"
}

# 获取最新版本号（返回 6 位数字字符串，如 000001）
# 如果没有任何版本，返回 000000
get_latest_version() {
    local metadata_dir="$1"
    
    if [[ ! -d "$metadata_dir" ]]; then
        echo "000000"
        return
    fi
    
    # 查找最大的版本号
    local latest
    latest=$(ls -1 "$metadata_dir"/*.txt 2>/dev/null | sed 's/.*\/\([0-9]\{6\}\)\.txt$/\1/' | sort -rn | head -1)
    
    if [[ -z "$latest" ]]; then
        echo "000000"
    else
        echo "$latest"
    fi
}

# 递增版本号
increment_version() {
    local current="$1"
    local next
    next=$(printf "%06d" $((10#$current + 1)))
    echo "$next"
}

# 从 metadata 文件读取 fingerprint
read_metadata_fingerprint() {
    local metadata_file="$1"
    if [[ -f "$metadata_file" ]]; then
        grep "^fingerprint=" "$metadata_file" | cut -d= -f2
    fi
}

# 从 metadata 文件读取 timestamp
read_metadata_timestamp() {
    local metadata_file="$1"
    if [[ -f "$metadata_file" ]]; then
        grep "^timestamp=" "$metadata_file" | cut -d= -f2
    fi
}

# 查找与指定 fingerprint 匹配的版本号
# 返回: 版本号 或 空字符串（未找到）
find_version_by_fingerprint() {
    local metadata_dir="$1"
    local target_fingerprint="$2"
    
    if [[ ! -d "$metadata_dir" ]]; then
        return
    fi
    
    for metadata_file in "$metadata_dir"/*.txt; do
        [[ -f "$metadata_file" ]] || continue
        local fp
        fp=$(read_metadata_fingerprint "$metadata_file")
        if [[ "$fp" == "$target_fingerprint" ]]; then
            # 从文件名提取版本号
            basename "$metadata_file" .txt
            return
        fi
    done
}

# 写入 metadata 文件
write_metadata() {
    local metadata_file="$1"
    local fingerprint="$2"
    local timestamp="$3"
    
    mkdir -p "$(dirname "$metadata_file")"
    cat > "$metadata_file" <<EOF
fingerprint=$fingerprint
timestamp=$timestamp
EOF
}

# 获取目录大小（带超时）
get_repo_size() {
    local repo_path="$1"
    du_timeout "$repo_path" 3
}

get_bundle_mode() {
    local repo_path="$1"

    if [[ -f "$repo_path/.gitignore" ]]; then
        echo "root .gitignore"
    else
        echo "legacy fallback"
    fi
}

# 提示用户确认是否继续
# 返回: 0=继续, 1=放弃, 2=临时跳过, 3=永久跳过
prompt_user_confirm() {
    local message=$1
    echo "" >&2
    log_warn_stderr "$message"
    echo "" >&2

    if [[ -n "$REPO_CONFIRM_ACTION" ]]; then
        log_info_stderr "自动处理: $REPO_CONFIRM_ACTION (--repo-confirm-action)"
        case "$REPO_CONFIRM_ACTION" in
            continue) return 0 ;;
            skip) return 2 ;;
            permanent) return 3 ;;
            abort) return 1 ;;
        esac
    fi

    echo "请选择操作:" >&2
    echo "  [c] 继续同步 (continue)" >&2
    echo "  [s] 临时跳过此仓库 (skip, 仅本次跳过)" >&2
    echo "  [p] 永久跳过此仓库 (permanent, 创建 $PERMANENT_IGNORE_FILE)" >&2
    echo "  [a] 放弃整个同步流程 (abort)" >&2
    echo "" >&2

    while true; do
        read -r -p "请输入选项 [c/s/p/a]: " choice
        case "$choice" in
            c|C) return 0 ;;
            s|S) return 2 ;;
            p|P) return 3 ;;
            a|A) return 1 ;;
            *) echo "无效选项，请输入 c、s、p 或 a" >&2 ;;
        esac
    done
}

# 检查 repo 大小并提示用户
# 参数: $1=repo路径, $2=relative_path, $3=当前大小, $4=旧大小(可选), $5=旧时间戳(可选)
# 返回: 0=继续, 1=放弃, 2=跳过, 3=永久跳过
check_repo_size() {
    local repo_path=$1
    local relative_path=$2
    local current_size=$3
    local old_size="${4:-}"
    local old_timestamp="${5:-}"

    if [[ -n "$old_size" ]] && [[ "$old_size" -gt 0 ]]; then
        # 有上次同步记录，检查增长百分比
        local increase_percent
        increase_percent=$(awk "BEGIN {printf \"%.1f\", ($current_size - $old_size) * 100.0 / $old_size}")
        local increase_percent_int
        increase_percent_int=$(awk "BEGIN {printf \"%d\", ($current_size - $old_size) * 100 / $old_size}")

        if [[ "$increase_percent_int" -gt "$SIZE_INCREASE_THRESHOLD" ]]; then
            local msg="仓库 '$relative_path' 大小增长异常 (${SIZE_INCREASE_THRESHOLD}%)"
            msg+="\n  ├─ 路径: $repo_path"
            [[ -n "$old_timestamp" ]] && msg+="\n  ├─ 上次同步: $old_timestamp"
            msg+="\n  ├─ 上次大小: $(numfmt --to=iec --suffix=B "$old_size")"
            msg+="\n  ├─ 当前大小: $(numfmt --to=iec --suffix=B "$current_size")"
            msg+="\n  └─ 增长幅度: +${increase_percent}%"

            prompt_user_confirm "$(echo -e "$msg")"
            return $?
        fi
    else
        # 没有上次同步记录，检查是否超过阈值
        if [[ $current_size -gt $FIRST_SYNC_SIZE_THRESHOLD ]]; then
            local msg="首次同步的大型仓库: '$relative_path'"
            msg+="\n  ├─ 路径: $repo_path"
            msg+="\n  └─ 当前大小: $(numfmt --to=iec --suffix=B "$current_size") (超过阈值 $(numfmt --to=iec --suffix=B "$FIRST_SYNC_SIZE_THRESHOLD"))"

            prompt_user_confirm "$(echo -e "$msg")"
            return $?
        fi
    fi

    return 0
}

# 打包仓库到 tgz
create_bundle() {
    local repo_path="$1"
    local output_file="$2"

    bash "$BUNDLE_HELPER_SCRIPT" "$repo_path" "$output_file"
}

# ================= 主流程 =================

log_header_stderr "Bundle Repos - 扫描并打包 Git 仓库"
log_info_stderr "同步根目录: $SYNC_ROOT"
log_info_stderr "Bundle 目录: $BUNDLE_DIR"
if [[ "$DRY_RUN" == true ]]; then
    log_info_stderr "模式: DRY-RUN (不会修改任何文件)"
fi
if [[ -n "$REPO_CONFIRM_ACTION" ]]; then
    log_info_stderr "仓库级确认默认动作: $REPO_CONFIRM_ACTION"
fi

# --- 创建 Bundle 目录 ---
if [[ "$DRY_RUN" != true ]]; then
    mkdir -p "$BUNDLE_DIR"
fi

# --- 初始确认 ---
if [[ "$NO_CONFIRM" != true && "$DRY_RUN" != true ]]; then
    echo >&2
    read -p "是否确认开始打包操作？(y/n): " confirm_sync
    case "$confirm_sync" in
        y|Y )
            log_info_stderr "已确认，开始打包。"
            ;;
        * )
            log_warn_stderr "取消打包。"
            exit 2
            ;;
    esac
fi

# --- 扫描 Git 仓库 ---
log_info_stderr "扫描 Git 仓库..."

repo_list=()
permanently_ignored_repos=()
while IFS= read -r -d '' repo_path; do
    if [[ -f "$repo_path/$PERMANENT_IGNORE_FILE" ]]; then
        permanently_ignored_repos+=("$repo_path")
    else
        repo_list+=("$repo_path")
    fi
done < <(find -H "$SYNC_ROOT" -type d -exec test -d "{}/.git" \; -print0 -prune)

count_permanent=${#permanently_ignored_repos[@]}
log_info_stderr "发现 ${#repo_list[@]} 个 Git 仓库。"
if [[ "$count_permanent" -gt 0 ]]; then
    log_info_stderr "另有 $count_permanent 个仓库已被永久跳过 (包含 $PERMANENT_IGNORE_FILE)"
fi

# --- 处理每个仓库 ---
log_info_stderr "开始检查仓库状态..."

total_repos=${#repo_list[@]}
current_idx=0

for repo_path in "${repo_list[@]}"; do
    ((current_idx++))
    relative_path="${repo_path#$SYNC_ROOT/}"
    repo_bundle_dir=$(get_repo_bundle_dir "$relative_path")
    metadata_dir=$(get_repo_metadata_dir "$relative_path")
    
    # 使用 \r 刷新当前进度，仅作为临时状态
    refresh=true level=IN_PROGRESS log "[$current_idx/$total_repos] 🔍 正在检查: $relative_path" >&2
    
    # 计算当前 fingerprint
    [[ "$DEBUG" == true ]] && _t0=$(date +%s.%N)
    current_fingerprint=$(get_repo_fingerprint "$repo_path")
    if [[ "$DEBUG" == true ]]; then
        _t1=$(date +%s.%N)
        _elapsed=$(awk "BEGIN {printf \"%.2f\", $_t1 - $_t0}")
        log_info_stderr "  [DEBUG] fingerprint: ${_elapsed}s"
    fi
    
    # 获取最新版本信息
    [[ "$DEBUG" == true ]] && _t0=$(date +%s.%N)
    latest_version=$(get_latest_version "$metadata_dir")
    if [[ "$DEBUG" == true ]]; then
        _t1=$(date +%s.%N)
        _elapsed=$(awk "BEGIN {printf \"%.2f\", $_t1 - $_t0}")
        log_info_stderr "  [DEBUG] get_latest_version: ${_elapsed}s"
    fi
    
    # 获取目录大小（用于大小检查）
    [[ "$DEBUG" == true ]] && _t0=$(date +%s.%N)
    current_size=$(get_repo_size "$repo_path")
    if [[ "$DEBUG" == true ]]; then
        _t1=$(date +%s.%N)
        _elapsed=$(awk "BEGIN {printf \"%.2f\", $_t1 - $_t0}")
        log_info_stderr "  [DEBUG] get_repo_size: ${_elapsed}s"
    fi
    
    # 确定状态
    if [[ "$latest_version" == "000000" ]]; then
        # 新仓库
        status="NEW"
        new_version="000001"
        
        # 清除正在检查的临时行，准备显示交互提示或持久日志
        printf "\r\033[K" >&2
        
        # 大小检查
        check_repo_size "$repo_path" "$relative_path" "$current_size" "" ""
        check_result=$?
        
        case $check_result in
            1) log_error_stderr "用户取消同步流程。"; exit 2 ;;
            2)
                [[ "$DRY_RUN" != true ]] && touch "$repo_path/$TEMP_IGNORE_FILE"
                REPOS_SKIPPED+=("$relative_path")
                log_warn_stderr "[$current_idx/$total_repos] ⏩ 临时跳过: $relative_path"
                continue
                ;;
            3)
                [[ "$DRY_RUN" != true ]] && touch "$repo_path/$PERMANENT_IGNORE_FILE"
                REPOS_SKIPPED+=("$relative_path")
                log_warn_stderr "[$current_idx/$total_repos] 🛑 永久跳过: $relative_path"
                continue
                ;;
        esac
        
    else
        # 检查 fingerprint 是否匹配
        latest_metadata_file="$metadata_dir/${latest_version}.txt"
        latest_fingerprint=$(read_metadata_fingerprint "$latest_metadata_file")
        latest_timestamp=$(read_metadata_timestamp "$latest_metadata_file")
        
        if [[ "$current_fingerprint" == "$latest_fingerprint" ]]; then
            # 匹配最新版本
            status="UP_TO_DATE"
            REPOS_UP_TO_DATE+=("$relative_path")
            # 创建临时忽略标记
            [[ "$DRY_RUN" != true ]] && touch "$repo_path/$TEMP_IGNORE_FILE"
            continue
            
        else
            # 检查是否匹配某个旧版本
            [[ "$DEBUG" == true ]] && _t0=$(date +%s.%N)
            matched_version=$(find_version_by_fingerprint "$metadata_dir" "$current_fingerprint")
            if [[ "$DEBUG" == true ]]; then
                _t1=$(date +%s.%N)
                _elapsed=$(awk "BEGIN {printf \"%.2f\", $_t1 - $_t0}")
                log_info_stderr "  [DEBUG] find_version_by_fingerprint: ${_elapsed}s"
            fi
            
            if [[ -n "$matched_version" ]]; then
                # 匹配旧版本 - 本地落后
                status="BEHIND"
                local_timestamp=$(read_metadata_timestamp "$metadata_dir/${matched_version}.txt")
                REPOS_BEHIND+=("$relative_path")
                REPO_BEHIND_INFO["$relative_path"]="本地 v$matched_version ($local_timestamp) | 云端 v$latest_version ($latest_timestamp)"
                
                # 清除正在检查的临时行
                printf "\r\033[K" >&2
                log_warn_stderr "[$current_idx/$total_repos] ⚠️  本地落后: $relative_path (本地 v$matched_version, 云端 v$latest_version)"
                
                # 创建临时忽略标记（不更新）
                [[ "$DRY_RUN" != true ]] && touch "$repo_path/$TEMP_IGNORE_FILE"
                continue
                
            else
                # 不匹配任何版本 - 有新改动
                status="UPDATED"
                new_version=$(increment_version "$latest_version")
                
                # 清除正在检查的临时行
                printf "\r\033[K" >&2
                
                # 大小检查
                check_repo_size "$repo_path" "$relative_path" "$current_size" "" "$latest_timestamp"
                check_result=$?
                
                case $check_result in
                    1) log_error_stderr "用户取消同步流程。"; exit 2 ;;
                    2)
                        [[ "$DRY_RUN" != true ]] && touch "$repo_path/$TEMP_IGNORE_FILE"
                        REPOS_SKIPPED+=("$relative_path")
                        log_warn_stderr "[$current_idx/$total_repos] ⏩ 临时跳过: $relative_path"
                        continue
                        ;;
                    3)
                        [[ "$DRY_RUN" != true ]] && touch "$repo_path/$PERMANENT_IGNORE_FILE"
                        REPOS_SKIPPED+=("$relative_path")
                        log_warn_stderr "[$current_idx/$total_repos] 🛑 永久跳过: $relative_path"
                        continue
                        ;;
                esac
            fi
        fi
    fi
    
    # 执行打包（NEW 或 UPDATED）
    if [[ "$status" == "NEW" || "$status" == "UPDATED" ]]; then
        bundle_file="$repo_bundle_dir/${new_version}.tgz"
        metadata_file="$metadata_dir/${new_version}.txt"
        bundle_mode=$(get_bundle_mode "$repo_path")
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info_stderr "[$current_idx/$total_repos] [DRY-RUN] 📦 将创建: $bundle_file ($bundle_mode)"
        else
            # 清除正在检查的临时行
            printf "\r\033[K" >&2
            log_info_stderr "[$current_idx/$total_repos] 📦 打包: $relative_path -> v$new_version ($bundle_mode)"
            if create_bundle "$repo_path" "$bundle_file"; then
                :
            else
                log_error_stderr "[$current_idx/$total_repos] 打包失败: $relative_path"
                exit 1
            fi
            write_metadata "$metadata_file" "$current_fingerprint" "$CURRENT_TIMESTAMP"
            # 创建临时忽略标记
            touch "$repo_path/$TEMP_IGNORE_FILE"
        fi
        
        # 记录统计信息
        if [[ "$status" == "NEW" ]]; then
            REPOS_NEW+=("$relative_path")
        else
            REPOS_UPDATED+=("$relative_path")
        fi
        REPO_VERSION["$relative_path"]="$new_version"
        REPO_TIMESTAMP["$relative_path"]="$CURRENT_TIMESTAMP"
    fi
done

# 完成循环后，确保最后一行临时状态被清除
printf "\r\033[K" >&2

# ================= 输出统计报告 =================

echo ""
log_header "Bundle Summary Report"

# 计算需要显示的行数来决定树形分支符号
declare -a summary_lines=()
summary_lines+=("New|${#REPOS_NEW[@]}")
summary_lines+=("Updated|${#REPOS_UPDATED[@]}")
summary_lines+=("Up-to-date|${#REPOS_UP_TO_DATE[@]}")
summary_lines+=("Behind|${#REPOS_BEHIND[@]}")
[[ ${#REPOS_SKIPPED[@]} -gt 0 ]] && summary_lines+=("Skipped|${#REPOS_SKIPPED[@]}")
[[ $count_permanent -gt 0 ]]     && summary_lines+=("Permanently Ignored|$count_permanent")

printf "  Total Repositories:     %4d\n" "${#repo_list[@]}"
total_lines=${#summary_lines[@]}
for i in "${!summary_lines[@]}"; do
    IFS='|' read -r label count <<< "${summary_lines[$i]}"
    if [[ $((i + 1)) -eq $total_lines ]]; then
        printf "  └─ %-22s %4d\n" "$label:" "$count"
    else
        printf "  ├─ %-22s %4d\n" "$label:" "$count"
    fi
done

if [[ ${#REPOS_NEW[@]} -gt 0 ]]; then
    echo ""
    log_info "--- [✨ New Repositories] ---"
    for repo in "${REPOS_NEW[@]}"; do
        printf "  • %-45s v%s  %s\n" "$repo" "${REPO_VERSION[$repo]}" "${REPO_TIMESTAMP[$repo]}"
    done
fi

if [[ ${#REPOS_UPDATED[@]} -gt 0 ]]; then
    echo ""
    log_info "--- [📦 Updated Repositories] ---"
    for repo in "${REPOS_UPDATED[@]}"; do
        printf "  • %-45s v%s  %s\n" "$repo" "${REPO_VERSION[$repo]}" "${REPO_TIMESTAMP[$repo]}"
    done
fi

if [[ ${#REPOS_BEHIND[@]} -gt 0 ]]; then
    echo ""
    log_warn "--- [⚠️  Behind Repositories (not updated)] ---"
    for repo in "${REPOS_BEHIND[@]}"; do
        printf "  • %s\n" "$repo"
        printf "    └─ %s\n" "${REPO_BEHIND_INFO[$repo]}"
    done
fi
echo ""
