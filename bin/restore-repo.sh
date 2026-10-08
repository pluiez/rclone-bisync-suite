#!/bin/bash
set -euo pipefail

# ================= 参数定义 =================
KEYWORD=""
VERSION=""
FORCE=false
TARGET_PATH=""
NO_CONFIRM=false

# ================= 函数定义 =================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] <KEYWORD>

Restore git repositories from bundles by searching with a keyword.

Options:
  -h, --help         Show this help message and exit
  -v, --version VER  Restore a specific version (e.g., 000001). Default: latest
  -l, --list         List available versions for matching repos (don't restore)
  -f, --force        Replace existing target directories safely via backup + rename
  --no-confirm       Skip the restore confirmation prompt
  -t, --target-path  Restore the matched repo to a specific non-existent path

Arguments:
  KEYWORD            Keyword to search for in repository paths (case-insensitive).
                     Matches against the full relative path.
                     Use "*" to match all repositories.

Examples:
  $(basename "$0") my-project              # Restore repos matching "my-project"
  $(basename "$0") scripts/tools           # Restore repos matching path "scripts/tools"
  $(basename "$0") -l my-project           # List available versions
  $(basename "$0") -v 000002 my-project    # Restore specific version
  $(basename "$0") --force my-project      # Replace existing target with backup
  $(basename "$0") --no-confirm my-project # Run non-interactively
  $(basename "$0") --target-path /tmp/app my-project
  $(basename "$0") "*"                     # Restore all repositories

Note:
  Run bisync first to fetch the latest bundles from remote storage.
EOF
    exit 0
}

# ================= 初始化 =================

# 引用公共库
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOURCE_DIR/../lib/utils.sh"

# ================= 参数解析 =================

LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -v|--version)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "Option $1 requires a value"
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --no-confirm)
            NO_CONFIRM=true
            shift
            ;;
        -t|--target-path)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                log_error "Option --target-path requires a value"
                exit 1
            fi
            TARGET_PATH="$2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -n "$KEYWORD" ]]; then
                log_error "Only one KEYWORD is allowed. Unexpected extra argument: $1"
                exit 1
            fi
            KEYWORD="$1"
            shift
            ;;
    esac
done

# ================= 加载配置 =================
load_config

# 检查必需的配置变量
[[ -n "${SYNC_ROOT:-}" ]] || { log_error "SYNC_ROOT is not set or empty. Please define it in config/rclone.env" && exit 1; }

# 展开 ~ 为 home 目录，并移除尾部斜杠
SYNC_ROOT="${SYNC_ROOT/#\~/$HOME}"
SYNC_ROOT="${SYNC_ROOT%/}"
if [[ -n "$TARGET_PATH" ]]; then
    TARGET_PATH="${TARGET_PATH/#\~/$HOME}"
    if [[ "$TARGET_PATH" != "/" ]]; then
        TARGET_PATH="${TARGET_PATH%/}"
    fi
fi

# 检查必需的参数
[[ -n "${KEYWORD:-}" ]] || { log_error "Usage: $(basename "$0") <KEYWORD>. Run '$(basename "$0") --help' for more information." && exit 1; }
if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]{6}$ ]]; then
    log_error "--version expects a 6-digit value like 000001"
    exit 1
fi
if [[ -n "$TARGET_PATH" && "$LIST_ONLY" == true ]]; then
    log_error "--target-path cannot be used together with --list"
    exit 1
fi
if [[ -n "$TARGET_PATH" && "$FORCE" == true ]]; then
    log_error "--target-path requires a non-existent target path, so it cannot be used together with --force"
    exit 1
fi

# 检查依赖
check_dependency "tar"

# ================= 内部变量 =================

BUNDLE_DIR="$SYNC_ROOT/git_bundles"
declare -a PLAN_RELATIVE_PATHS=()
declare -a PLAN_EXPECTED_REPO_NAMES=()
declare -a PLAN_VERSIONS=()
declare -a PLAN_TIMESTAMPS=()
declare -a PLAN_BUNDLE_FILES=()
declare -a PLAN_TARGET_PATHS=()
declare -a PLAN_TARGET_STATES=()
declare -a PLAN_ACTIONS=()

# ================= 工具函数 =================

list_metadata_version_files() {
    local metadata_dir="$1"

    if [[ ! -d "$metadata_dir" ]]; then
        return 0
    fi

    find "$metadata_dir" \
        -maxdepth 1 \
        -type f \
        -regextype posix-extended \
        -regex '.*/[0-9]{6}\.txt' \
        -print0 2>/dev/null
}

# 获取最新版本号
get_latest_version() {
    local metadata_dir="$1"
    local metadata_file
    local latest=""
    
    while IFS= read -r -d '' metadata_file; do
        local ver
        ver=$(basename "$metadata_file" .txt)
        if [[ -z "$latest" || "$ver" > "$latest" ]]; then
            latest="$ver"
        fi
    done < <(list_metadata_version_files "$metadata_dir")

    echo "$latest"
}

# 列出所有版本
list_versions() {
    local metadata_dir="$1"
    local metadata_file
    
    while IFS= read -r -d '' metadata_file; do
        local ver
        ver=$(basename "$metadata_file" .txt)
        local timestamp
        timestamp=$(sed -n 's/^timestamp=//p' "$metadata_file" | head -n 1)
        local bundle_file="${metadata_dir%/metadata}/${ver}.tgz"
        local exists="[missing]"
        [[ -f "$bundle_file" ]] && exists="[exists]"
        printf "    v%s  %s  %s\n" "$ver" "$timestamp" "$exists"
    done < <(list_metadata_version_files "$metadata_dir" | sort -z -r)
}

# 从 metadata 文件读取 timestamp
read_metadata_timestamp() {
    local metadata_file="$1"
    if [[ -f "$metadata_file" ]]; then
        sed -n 's/^timestamp=//p' "$metadata_file" | head -n 1
    fi
}

path_exists() {
    local target_path="$1"
    [[ -e "$target_path" || -L "$target_path" ]]
}

get_target_state() {
    local target_path="$1"

    if path_exists "$target_path"; then
        echo "exists"
    else
        echo "missing"
    fi
}

validate_bundle_layout() {
    local bundle_file="$1"
    local expected_root="$2"
    local entry
    local top_level=""
    local found_entries=false
    local entries=()

    if mapfile -t entries < <(tar tzf "$bundle_file"); then
        :
    else
        log_error "无法读取 bundle 目录结构: $bundle_file"
        return 1
    fi

    for entry in "${entries[@]}"; do
        [[ -n "$entry" ]] || continue
        found_entries=true

        if [[ "$entry" == /* ]]; then
            log_error "Bundle 包含绝对路径，拒绝还原: $entry"
            return 1
        fi

        if [[ "$entry" == ".." || "$entry" == ../* || "$entry" == */../* ]]; then
            log_error "Bundle 包含非法相对路径，拒绝还原: $entry"
            return 1
        fi

        local normalized="${entry#./}"
        local current_top="${normalized%%/*}"
        current_top="${current_top%/}"

        if [[ -z "$current_top" ]]; then
            log_error "Bundle 顶层路径无效: $entry"
            return 1
        fi

        if [[ -z "$top_level" ]]; then
            top_level="$current_top"
        elif [[ "$top_level" != "$current_top" ]]; then
            log_error "Bundle 包含多个顶层路径，拒绝还原: $top_level, $current_top"
            return 1
        fi
    done

    if [[ "$found_entries" != true ]]; then
        log_error "Bundle 内容为空: $bundle_file"
        return 1
    fi

    if [[ "$top_level" != "$expected_root" ]]; then
        log_error "Bundle 顶层目录不匹配: 期望 '$expected_root'，实际 '$top_level'"
        return 1
    fi
}

make_backup_path() {
    local target_path="$1"
    local timestamp
    local backup_path

    timestamp=$(date '+%Y%m%d-%H%M%S')
    backup_path="${target_path}.backup.${timestamp}"

    while [[ -e "$backup_path" ]]; do
        backup_path="${target_path}.backup.${timestamp}-$RANDOM"
    done

    echo "$backup_path"
}

discover_repo_relative_paths() {
    local bundle_dir="$1"
    local metadata_file
    local relative_path
    declare -A seen_relative_paths=()

    while IFS= read -r -d '' metadata_file; do
        relative_path="${metadata_file#$bundle_dir/}"
        relative_path="${relative_path%/metadata/*}"
        [[ -n "$relative_path" ]] || continue
        seen_relative_paths["$relative_path"]=1
    done < <(
        find "$bundle_dir" \
            -type f \
            -regextype posix-extended \
            -regex '.*/metadata/[0-9]{6}\.txt' \
            -print0 2>/dev/null
    )

    for relative_path in "${!seen_relative_paths[@]}"; do
        printf '%s\0' "$relative_path"
    done | sort -z
}

restore_bundle_safely() {
    local bundle_file="$1"
    local expected_repo_name="$2"
    local target_full_path="$3"
    local allow_replace="$4"
    local target_parent_dir
    local target_name
    local stage_dir
    local staged_repo_path
    local backup_path=""

    target_name=$(basename "$target_full_path")
    target_parent_dir=$(dirname "$target_full_path")

    mkdir -p "$target_parent_dir" || {
        log_error "无法创建目标父目录: $target_parent_dir"
        return 1
    }

    if path_exists "$target_full_path" && [[ "$allow_replace" != true ]]; then
        log_error "目标路径已存在，默认拒绝覆盖: $target_full_path"
        log_warn "如需替换现有目录，请显式传入 --force"
        return 1
    fi

    validate_bundle_layout "$bundle_file" "$expected_repo_name" || return 1

    stage_dir=$(mktemp -d "$target_parent_dir/.${target_name}.staging.XXXXXX") || {
        log_error "无法创建临时还原目录"
        return 1
    }

    if tar xzf "$bundle_file" -C "$stage_dir"; then
        :
    else
        log_error "解压到临时目录失败"
        rm -rf "$stage_dir"
        return 1
    fi

    staged_repo_path="$stage_dir/$expected_repo_name"
    if [[ ! -d "$staged_repo_path" ]]; then
        log_error "临时还原结果缺少仓库目录: $staged_repo_path"
        rm -rf "$stage_dir"
        return 1
    fi

    if [[ ! -d "$staged_repo_path/.git" ]]; then
        log_error "临时还原结果缺少 .git 目录: $staged_repo_path/.git"
        rm -rf "$stage_dir"
        return 1
    fi

    if path_exists "$target_full_path"; then
        backup_path=$(make_backup_path "$target_full_path")
        if mv "$target_full_path" "$backup_path"; then
            log_warn "现有目标已备份: $backup_path"
        else
            log_error "无法备份现有目标: $target_full_path"
            rm -rf "$stage_dir"
            return 1
        fi
    fi

    if mv "$staged_repo_path" "$target_full_path"; then
        rmdir "$stage_dir" 2>/dev/null || true
        log_info "还原完成"
        return 0
    fi

    log_error "无法将临时还原目录切换到目标路径: $target_full_path"
    rm -rf "$stage_dir"

    if [[ -n "$backup_path" ]]; then
        if mv "$backup_path" "$target_full_path"; then
            log_warn "已回滚到原目标目录: $target_full_path"
        else
            log_error "回滚失败，备份仍保留在: $backup_path"
        fi
    fi

    return 1
}

print_restore_plan() {
    local total_plans=${#PLAN_RELATIVE_PATHS[@]}

    echo ""
    log_header "Restore Plan"
    log_info "待执行操作: $total_plans 个"
    if [[ "$NO_CONFIRM" == true ]]; then
        log_info "开始确认:   已跳过 (--no-confirm)"
    fi

    for idx in "${!PLAN_RELATIVE_PATHS[@]}"; do
        local display_idx=$((idx + 1))
        echo ""
        printf "  [%d/%d] %s\n" "$display_idx" "$total_plans" "${PLAN_RELATIVE_PATHS[$idx]}"
        printf "    version:      v%s (%s)\n" "${PLAN_VERSIONS[$idx]}" "${PLAN_TIMESTAMPS[$idx]}"
        printf "    bundle:       %s\n" "${PLAN_BUNDLE_FILES[$idx]}"
        printf "    target:       %s\n" "${PLAN_TARGET_PATHS[$idx]}"
        printf "    target state: %s\n" "${PLAN_TARGET_STATES[$idx]}"
        printf "    action:       %s\n" "${PLAN_ACTIONS[$idx]}"
    done
}

# ================= 主流程 =================

if [[ ! -d "$BUNDLE_DIR" ]]; then
    log_error "Bundle 目录不存在: $BUNDLE_DIR"
    log_warn "请先运行一次 bisync 以拉取最新的 bundles。"
    exit 1
fi

log_header "搜索仓库: '$KEYWORD'"

# 扫描所有仓库（根据 metadata/{version}.txt 推导 repo 相对路径）
declare -a matched_repos=()
KEYWORD_LOWER="${KEYWORD,,}"

while IFS= read -r -d '' relative_path; do
    # 匹配关键字
    if [[ "$KEYWORD" == "*" || "${relative_path,,}" == *"$KEYWORD_LOWER"* ]]; then
        matched_repos+=("$relative_path")
    fi
done < <(discover_repo_relative_paths "$BUNDLE_DIR")

if [[ ${#matched_repos[@]} -eq 0 ]]; then
    log_warn "未找到匹配的仓库。"
    exit 0
fi

match_count=${#matched_repos[@]}
log_info "找到 $match_count 个匹配的仓库。"

if [[ -n "$TARGET_PATH" && $match_count -ne 1 ]]; then
    log_error "--target-path 只能用于恰好匹配 1 个仓库的场景，当前匹配到: $match_count 个"
    exit 1
fi

# 如果是列表模式，显示版本信息后退出
if [[ "$LIST_ONLY" == true ]]; then
    for relative_path in "${matched_repos[@]}"; do
        repo_bundle_dir="$BUNDLE_DIR/$relative_path"
        metadata_dir="$repo_bundle_dir/metadata"
        
        echo ""
        echo "仓库: $relative_path"
        list_versions "$metadata_dir"
    done
    exit 0
fi

# 构建还原计划
for relative_path in "${matched_repos[@]}"; do
    repo_bundle_dir="$BUNDLE_DIR/$relative_path"
    metadata_dir="$repo_bundle_dir/metadata"
    expected_repo_name=$(basename "$relative_path")

    if [[ -n "$VERSION" ]]; then
        target_version="$VERSION"
    else
        target_version=$(get_latest_version "$metadata_dir")
    fi

    if [[ -z "$target_version" ]]; then
        log_error "无法确定版本号: $relative_path"
        exit 1
    fi

    bundle_file="$repo_bundle_dir/${target_version}.tgz"
    metadata_file="$metadata_dir/${target_version}.txt"

    if [[ ! -f "$bundle_file" ]]; then
        log_error "Bundle 文件不存在: $bundle_file"
        log_warn "可用的版本:"
        list_versions "$metadata_dir"
        exit 1
    fi

    validate_bundle_layout "$bundle_file" "$expected_repo_name" || exit 1

    timestamp=$(read_metadata_timestamp "$metadata_file")
    if [[ -z "$timestamp" ]]; then
        timestamp="unknown"
    fi

    if [[ -n "$TARGET_PATH" ]]; then
        target_full_path="$TARGET_PATH"
    else
        target_full_path="$SYNC_ROOT/$relative_path"
    fi

    target_state=$(get_target_state "$target_full_path")
    if [[ "$target_state" == "exists" && "$FORCE" == true ]]; then
        action="replace (--force)"
    elif [[ "$target_state" == "exists" ]]; then
        log_error "目标路径已存在，默认拒绝覆盖: $target_full_path"
        log_warn "如需替换现有目录，请显式传入 --force"
        exit 1
    elif [[ -n "$TARGET_PATH" ]]; then
        action="restore (custom target)"
    else
        action="restore"
    fi

    PLAN_RELATIVE_PATHS+=("$relative_path")
    PLAN_EXPECTED_REPO_NAMES+=("$expected_repo_name")
    PLAN_VERSIONS+=("$target_version")
    PLAN_TIMESTAMPS+=("$timestamp")
    PLAN_BUNDLE_FILES+=("$bundle_file")
    PLAN_TARGET_PATHS+=("$target_full_path")
    PLAN_TARGET_STATES+=("$target_state")
    PLAN_ACTIONS+=("$action")
done

print_restore_plan

if [[ "$NO_CONFIRM" != true ]]; then
    echo ""
    if ! read -r -p "确认执行以上 ${#PLAN_RELATIVE_PATHS[@]} 个还原操作? [y/N] " confirm; then
        log_error "无法读取确认输入"
        exit 1
    fi
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消。"
        exit 0
    fi
fi

# 还原仓库
restored_count=0
failed_count=0

for idx in "${!PLAN_RELATIVE_PATHS[@]}"; do
    relative_path="${PLAN_RELATIVE_PATHS[$idx]}"
    log_info "----------------------------------------"
    log_info "仓库: $relative_path"

    target_version="${PLAN_VERSIONS[$idx]}"
    timestamp="${PLAN_TIMESTAMPS[$idx]}"
    bundle_file="${PLAN_BUNDLE_FILES[$idx]}"
    target_full_path="${PLAN_TARGET_PATHS[$idx]}"
    expected_repo_name="${PLAN_EXPECTED_REPO_NAMES[$idx]}"

    log_info "版本: v$target_version ($timestamp)"
    log_info "目标路径: $target_full_path"

    if [[ "${PLAN_TARGET_STATES[$idx]}" == "exists" && "$FORCE" == true ]]; then
        log_warn "目标路径已存在，将通过备份后替换: $target_full_path"
    fi

    log_info "正在以安全模式还原..."
    if restore_bundle_safely "$bundle_file" "$expected_repo_name" "$target_full_path" "$FORCE"; then
        restored_count=$((restored_count + 1))
    else
        log_error "还原失败"
        failed_count=$((failed_count + 1))
    fi
done

# 最终统计
echo ""
log_header "还原完成"
log_info "成功: $restored_count 个仓库"
if [[ $failed_count -gt 0 ]]; then
    log_warn "失败: $failed_count 个仓库"
    exit 1
fi
