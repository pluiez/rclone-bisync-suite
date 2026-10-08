#!/bin/bash

# 获取脚本所在的根目录 (假设 utils.sh 在 lib/ 下)
# 结果类似: /Users/username/rclone-bisync-suite
export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 引用日志库
source "${PROJECT_ROOT}/lib/log.sh"

# 加载配置
load_config() {
    local env_file="${PROJECT_ROOT}/config/rclone.env"
    if [ -f "$env_file" ]; then
        source "$env_file"
    else
        log_error "配置文件未找到: $env_file"
        exit 1
    fi
}

# 依赖检查
check_dependency() {
    if ! command -v "$1" &> /dev/null; then
        log_error "未找到命令: $1。请先安装。"
        exit 1
    fi
}

is_valid_repo_confirm_action() {
    case "$1" in
        continue|skip|permanent|abort)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_dir_size_over() {
    local dir="$1"
    local size_arg="$2"

    # 执行流式扫描
    # find 输出文件大小 -> awk 累加 -> 超过 limit 立即 exit 0 (真) -> 否则 END 时 exit 1 (假)
    # 2>/dev/null 用于屏蔽 find 因为管道断裂(Broken pipe)产生的报错信息
    find "$dir" -type f -printf "%s\n" 2>/dev/null | awk -v limit="$limit_bytes" '
        { sum += $1 }
        sum > limit { exit }
        END { if (sum <= limit) exit 1; else exit 0 }
    '
}

# is_dir_size_over "." "500k" && echo "超过 500KB"
# is_dir_size_over "." "1G"   && echo "超过 1GB"
# is_dir_size_over "." "1.5g" && echo "超过 1.5GB"  # 支持小数


function du_timeout() {
    local target_dir="$1"
    local timeout_sec="${2:-5}" # 默认超时 5 秒

    # 1. 检查目录是否存在
    if [ ! -d "$target_dir" ]; then
        return 1
    fi

    # 2. 执行核心逻辑
    # -printf "%s\n": 只输出文件大小（字节），避免处理文件名的额外开销
    find "$target_dir" -type f -printf "%s\n" 2>/dev/null | awk -v limit="$timeout_sec" '
        BEGIN { 
            start_time = systime(); 
            sum = 0; 
        }
        {
            sum += $1;
            
            # 性能优化：每处理 1000 个文件检查一次时间
            # 避免对每个文件都调用系统时钟，减少开销
            if (NR % 1000 == 0) {
                current_time = systime();
                if (current_time - start_time >= limit) {
                    # 标记为超时退出（可选，用于调试）
                    print "Timeout reached, returning estimated size" > "/dev/stderr"
                    exit 0; 
                }
            }
        }
        END { 
            # 无论是遍历完还是超时退出，都会执行这里
            print sum 
        }
    '
}

# 计算 Git 仓库指纹
# 指纹反映仓库的完整状态：提交、分支、标签、未提交的变更
# 注意：排除 .rclone_ignore 和 .rclone_ignore_tmp 文件，避免脚本标记文件影响 fingerprint
function get_repo_fingerprint() {
    local repo_path=$1
    local fingerprint
    fingerprint=$(
        cd "$repo_path" && \
        { git show-ref --head --heads --tags 2>/dev/null || true; \
          git status --porcelain 2>/dev/null | grep -v -E '\.rclone_ignore(_tmp)?$'; } | \
        md5sum | awk '{print $1}'
    )
    echo "$fingerprint"
}
