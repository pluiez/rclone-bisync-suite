#!/bin/bash
#set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") <GIT_REPO_PATH> <BUNDLE_FILE>

Create a bundle archive for a single Git repository.

Arguments:
  GIT_REPO_PATH  Path to the Git repository root
  BUNDLE_FILE    Output .tgz file path

Behavior:
  - If <GIT_REPO_PATH>/.gitignore exists, use only that file to exclude
    ignored untracked files from the bundle.
  - If .gitignore does not exist, fall back to the legacy tar excludes.
  - Always include .git so the repository can be restored directly.

Examples:
  $(basename "$0") ~/sync/workspace/app ~/tmp/app.tgz
EOF
    exit 0
}

if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    usage
fi

if [[ $# -ne 2 ]]; then
    echo "Usage: $(basename "$0") <GIT_REPO_PATH> <BUNDLE_FILE>" >&2
    exit 1
fi

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SOURCE_DIR/../lib/utils.sh"

REPO_PATH="${1/#\~/$HOME}"
OUTPUT_FILE="${2/#\~/$HOME}"
MANIFEST_FILE=""

cleanup() {
    [[ -n "$MANIFEST_FILE" && -f "$MANIFEST_FILE" ]] && rm -f "$MANIFEST_FILE"
}
trap cleanup EXIT

check_dependency "tar"
check_dependency "git"

[[ -d "$REPO_PATH" ]] || { log_error "Git 仓库目录不存在: $REPO_PATH"; exit 1; }

repo_path=$(cd "$REPO_PATH" && pwd -P)
repo_root=$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null) || {
    log_error "不是有效的 Git 仓库: $repo_path"
    exit 1
}
repo_root=$(cd "$repo_root" && pwd -P)

if [[ "$repo_root" != "$repo_path" ]]; then
    log_error "请输入 Git 仓库根目录，而不是其子目录: $repo_path"
    exit 1
fi

output_dir=$(dirname "$OUTPUT_FILE")
mkdir -p "$output_dir" || {
    log_error "无法创建输出目录: $output_dir"
    exit 1
}

create_bundle_from_root_gitignore() {
    local repo_path="$1"
    local output_file="$2"
    local repo_name
    local parent_dir

    repo_name=$(basename "$repo_path")
    parent_dir=$(dirname "$repo_path")
    MANIFEST_FILE=$(mktemp)

    # tar 需要父目录为基准，因此把 repo 名称补到每个清单项前面。
    printf '%s\0' "$repo_name/.git" > "$MANIFEST_FILE"
    while IFS= read -r -d '' path; do
        printf '%s/%s\0' "$repo_name" "$path" >> "$MANIFEST_FILE"
    done < <(
        git -C "$repo_path" ls-files -z --cached --others --exclude-from=.gitignore
    )

    tar -C "$parent_dir" --null -T "$MANIFEST_FILE" -czf "$output_file"
}

create_bundle_fallback() {
    local repo_path="$1"
    local output_file="$2"
    local repo_name
    local parent_dir

    repo_name=$(basename "$repo_path")
    parent_dir=$(dirname "$repo_path")

    tar czf "$output_file" \
        --exclude="node_modules" \
        --exclude=".DS_Store" \
        --exclude="__pycache__" \
        --exclude=".pytest_cache" \
        --exclude="*.pyc" \
        -C "$parent_dir" "$repo_name"
}

if [[ -f "$repo_path/.gitignore" ]]; then
    create_bundle_from_root_gitignore "$repo_path" "$OUTPUT_FILE"
else
    create_bundle_fallback "$repo_path" "$OUTPUT_FILE"
fi
