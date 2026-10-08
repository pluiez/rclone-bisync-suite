# Repository Guidelines

## Project Structure & Module Organization
This repository is a small Bash toolset for syncing a local tree with `rclone` while packaging Git repositories into versioned bundles. Keep executable entrypoints in `bin/` (`bisync.sh`, `bundle-repos.sh`, `restore-repo.sh`), shared helpers in `lib/` (`log.sh`, `utils.sh`), and runtime configuration in `config/` (`rclone.env`, `filters.txt`). Generated bundle output lives under the configured `SYNC_ROOT`, not in this repository.

## Build, Test, and Development Commands
Use shell-native checks instead of a build system:

- `bash -n bin/*.sh lib/*.sh`: syntax-check all scripts.
- `bin/bundle-repos.sh --dry-run [SYNC_ROOT]`: preview Git bundle creation without writing files.
- `bin/bisync.sh --dry-run`: preview the full `rclone bisync` flow with current config.
- `bin/restore-repo.sh -l <keyword>`: inspect matching bundle versions before restoring.
- `shellcheck bin/*.sh lib/*.sh`: recommended lint pass when `shellcheck` is available.

Run commands from the repository root so relative paths to `config/` and `lib/` resolve correctly.

## Coding Style & Naming Conventions
Scripts are Bash-first and currently use 4-space indentation. Keep global configuration names uppercase (`SYNC_ROOT`, `REMOTE_NAME`, `FILTER_FILE`) and prefer lowercase `snake_case` for functions and local variables (`load_config`, `get_repo_fingerprint`). Quote variable expansions, use arrays for command assembly, and place reusable logic in `lib/` rather than duplicating it across entrypoints. Route user-facing logging through `lib/log.sh`.

## Testing Guidelines
There is no dedicated automated test suite yet. Treat `bash -n` plus the relevant dry-run command as the minimum validation for every change. For behavior changes, test against a disposable sync root and record the exact command used, for example `bin/bundle-repos.sh --dry-run ~/tmp/sync-root`.

## Commit & Pull Request Guidelines
This directory is not currently inside a Git checkout, so no local history is available to infer project-specific commit conventions. Use short imperative commit subjects such as `Add restore version validation`. In pull requests, summarize operator-facing behavior changes, note config updates, link the related task, and include the verification commands you ran. For CLI output changes, paste sample terminal output instead of screenshots.

## Security & Configuration Tips
Keep `config/rclone.env` limited to local paths and remote aliases; store credentials in `rclone`'s own config, not in this repository. Review `config/filters.txt` carefully before changing exclusions, since it protects caches, temp files, and version-control metadata from accidental sync.
