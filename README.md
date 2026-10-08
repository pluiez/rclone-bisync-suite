# Rclone Bisync Suite

一个基于 Bash 的小型工具集，用来把本地目录通过 `rclone bisync` 同步到远端，并对 Git 仓库做额外保护：同步前先扫描 Git 仓库，按版本打包为 bundle，再参与同步；需要时也可以从已同步的 bundle 中恢复仓库。

## 目录结构

- `bin/`: 入口脚本
  - `bisync.sh`: 完整同步流程
  - `bundle-repos.sh`: 扫描并打包 Git 仓库
  - `create-repo-bundle.sh`: 独立打包单个 Git 仓库
  - `restore-repo.sh`: 从 bundle 恢复仓库
- `lib/`: 公共函数与日志封装
- `config/`: 本地配置与过滤规则
- `SYNC_ROOT/git_bundles/`: 运行时生成的 bundle 存储目录，不在本仓库内

## 依赖与前置条件

至少需要以下命令：

- `bash`
- `rclone`
- `git`
- `tar`

可选但推荐：

- `shellcheck`: 用于脚本静态检查

开始前请先完成 `rclone config`，确保远端别名可用。

## 配置

主要配置在 `config/rclone.env`：

```bash
SYNC_ROOT=~/host/sync/
REMOTE_NAME=gdrive:sync/
RCLONE_OPTS=""
FILTER_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/filters.txt"
```

- `SYNC_ROOT`: 本地同步根目录
- `REMOTE_NAME`: `rclone` 远端路径
- `RCLONE_OPTS`: 附加给 `rclone bisync` 的额外参数
- `FILTER_FILE`: 过滤规则文件，默认指向 `config/filters.txt`（按 `config/rclone.env` 自身所在目录解析，因此本仓库放在任意路径都可用）

`config/filters.txt` 会排除缓存、临时文件、`node_modules` 等不适合同步的内容。修改前先确认规则影响范围。

## 核心命令

### 1. 完整同步

```bash
bin/bisync.sh
bin/bisync.sh --dry-run
bin/bisync.sh --no-confirm
bin/bisync.sh --no-confirm --repo-confirm-action continue --dry-run
bin/bisync.sh -- --resync --verbose
```

说明：

- 默认流程：开始确认 -> 扫描/打包 Git 仓库 -> 执行 `rclone bisync`
- `--no-confirm`: 跳过最外层“是否开始同步”确认
- `--repo-confirm-action <continue|skip|permanent|abort>`: 为打包阶段的仓库级提示设置默认动作
- `--` 后的参数会原样透传给 `rclone bisync`

注意：仅传 `--no-confirm` 时，仓库级提示仍保持交互模式。

### 2. 仅扫描并打包 Git 仓库

```bash
bin/bundle-repos.sh
bin/bundle-repos.sh --dry-run
bin/bundle-repos.sh ~/my-sync-root
bin/bundle-repos.sh --no-confirm --repo-confirm-action skip
```

适合先单独检查哪些仓库会被打包、哪些仓库本地状态落后于云端 bundle。

### 2.1 单独测试单个仓库打包

```bash
bash bin/create-repo-bundle.sh /path/to/git_repo /path/to/bundle.tgz
```

行为说明：

- 如果仓库根目录存在 `.gitignore`，打包时只使用这份文件来排除未跟踪文件
- 会始终包含 `.git/`，便于直接恢复为 Git 仓库
- 如果仓库根目录没有 `.gitignore`，会回退到旧的内置排除规则

### 3. 从 bundle 恢复仓库

```bash
bin/restore-repo.sh -l my-project
bin/restore-repo.sh my-project
bin/restore-repo.sh --no-confirm my-project
bin/restore-repo.sh --force my-project
bin/restore-repo.sh --target-path /tmp/my-app my-project
bin/restore-repo.sh -v 000002 my-project
bin/restore-repo.sh "*"
```

建议先用 `-l/--list` 查看匹配仓库的可用版本，再执行恢复。

## 推荐工作流

1. 先配置 `config/rclone.env`，确认 `SYNC_ROOT` 和 `REMOTE_NAME` 正确。
2. 运行 `bin/bundle-repos.sh --dry-run` 检查仓库扫描结果。
3. 运行 `bin/bisync.sh --dry-run` 预览完整同步流程。
4. 确认无误后执行 `bin/bisync.sh`，或在自动化场景中使用 `--no-confirm` 与 `--repo-confirm-action`。
5. 如果需要找回某个仓库，先 `bin/restore-repo.sh -l <keyword>`，再按版本恢复。

## 安全与行为说明

- Git 仓库不会直接依赖普通文件同步，而是优先生成版本化 bundle。
- 当仓库根目录存在 `.gitignore` 时，bundle 内容会按该文件排除未跟踪文件；不会读取子目录 `.gitignore`、`.git/info/exclude` 或全局 Git ignore。
- `.gitignore` 不会排除已经被 Git 跟踪的文件；如果某些构建产物已经被跟踪，需要先在仓库层面取消跟踪。
- `.rclone_ignore` 表示永久跳过该仓库。
- `.rclone_ignore_tmp` 表示本次流程中的临时跳过标记；在 `bisync.sh` 流程结束时会清理。
- `bundle-repos.sh` 发现“首次同步的大仓库”或“大小增长异常”时，默认会交互确认；可通过 `--repo-confirm-action` 改成无交互行为。
- `restore-repo.sh` 在真正还原前会先打印完整 restore plan，并统一等待用户确认；自动化场景可显式传入 `--no-confirm` 跳过确认。
- `restore-repo.sh` 默认不会覆盖已存在的目标路径；如需替换，必须显式传入 `--force`，脚本会先解压到同级临时目录并备份旧目标后再切换。
- `restore-repo.sh --target-path /path/to/target <keyword>` 只能用于恰好匹配 1 个仓库的场景，且 `/path/to/target` 必须不存在；还原时会把 bundle 重命名到该路径，而不是要求路径 basename 与原 repo 名一致。
- 凭据不要写进本仓库，应交给 `rclone` 自身的配置管理。

## 开发与验证

在仓库根目录执行：

```bash
bash -n bin/*.sh lib/*.sh
shellcheck bin/*.sh lib/*.sh
bash bin/create-repo-bundle.sh /path/to/git_repo /tmp/repo.tgz
bin/bundle-repos.sh --dry-run ~/tmp/sync-root
bin/bisync.sh --dry-run
```

如果你要改脚本行为，优先保证帮助输出、README 和实际参数语义一致。更偏向仓库维护约定的说明见 `AGENTS.md`。
