# ShellCheck

[![CI](https://github.com/AxolotlBucketLabs/action-shellcheck/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/AxolotlBucketLabs/action-shellcheck/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A GitHub Action that runs [ShellCheck](https://www.shellcheck.net/) on shell scripts in your repository. Choose scan directories or pass an explicit file list, including changed files from another action.

## Use the action

```yaml
steps:
  - uses: actions/checkout@v7
  - name: Run ShellCheck
    uses: AxolotlBucketLabs/action-shellcheck@v2
```

The default `version` is `stable`. To use a fixed release, set a version such as `v0.11.0`. Set `version: system` to use a ShellCheck binary already available in `PATH`. If it is missing, the action fails with an error.

## Choose files to check

By default, the action scans the repository for known shell filenames and extensionless executable scripts with a shell shebang. Set `scandir` to one directory or a newline-separated list. Paths may contain spaces.

```yaml
- name: Run ShellCheck in selected directories
  uses: AxolotlBucketLabs/action-shellcheck@v2
  with:
    scandir: |
      scripts
      tools with spaces
```

Use `additional_files` for unusual filenames or relative path patterns. Patterns without `/` match filenames. Patterns containing `/` match paths.

```yaml
- name: Check generated scripts
  uses: AxolotlBucketLabs/action-shellcheck@v2
  with:
    additional_files: helpers/helpers.v2.1.d/*
```

Set `all_scripts: true` to include extensionless executable files with any shebang. Use this for shell scripts that have a nonstandard interpreter path. The option assumes those files contain shell code, so leave it off when the directory contains scripts for other languages.

To pass an explicit list, use `only_files`. It accepts one path per line, runs ShellCheck on the original files, applies the ignore inputs, and skips paths that no longer exist. When used, it takes the place of directory scanning.

```yaml
- name: Find changed shell scripts
  id: changed
  uses: tj-actions/changed-files@v47.0.6
  with:
    files: |
      **/*.sh
    separator: "\n"

- name: Check changed scripts
  uses: AxolotlBucketLabs/action-shellcheck@v2
  with:
    only_files: ${{ steps.changed.outputs.all_changed_files }}
```

Set `SHELLCHECK_OPTS` to pass additional ShellCheck flags:

```yaml
- name: Run ShellCheck with extra exclusions
  uses: AxolotlBucketLabs/action-shellcheck@v2
  env:
    SHELLCHECK_OPTS: -e SC2059 -e SC2034
```

## Ignore paths and names

`ignore_paths` accepts space-separated paths or glob patterns. `ignore_names` accepts space-separated filenames or filename patterns. For compatibility, `ignore` remains available and takes precedence over `ignore_paths` when set.

```yaml
- name: Run ShellCheck
  uses: AxolotlBucketLabs/action-shellcheck@v2
  with:
    ignore_paths: >-
      generated
      **/vendor/*.sh
    ignore_names: local.sh
```

Symbolic links are ignored by default. Set `ignore_symlinks: false` to check links to files. Directory links are not traversed.

## Output and annotations

The default `gcc` format creates GitHub annotations for ShellCheck errors, warnings, and notes. Set `disable_matcher: true` to turn them off. Other output formats are `checkstyle`, `diff`, `json`, `json1`, `quiet`, and `tty`.

The `files` output remains a space-separated list for compatibility. Use `files_list` for a newline-separated list that preserves spaces in file paths. The `options` output contains the action's format and severity options.

```yaml
- name: Run ShellCheck
  id: shellcheck
  uses: AxolotlBucketLabs/action-shellcheck@v2
  with:
    scandir: scripts

- name: Show checked files
  env:
    FILES: ${{ steps.shellcheck.outputs.files_list }}
  run: printf '%s\n' "$FILES"
```

Set `check_together: true` to pass all selected files to one ShellCheck process. This can help with `SC1090` and `SC1091`, but a very large file list may exceed the runner's argument limit.

## Runner requirements

The action supports Linux and macOS x64 and ARM64 runners. It also supports Linux 32-bit ARM where a matching ShellCheck release asset is available. Windows runners are not supported.

Self-hosted runners and job containers need Bash, `curl`, `tar` with xz support, `find`, `mktemp`, `od`, and `tr`. Set `version: system` only when ShellCheck is installed on the runner.

## License

This project is distributed under the MIT License. See [LICENSE](LICENSE).
