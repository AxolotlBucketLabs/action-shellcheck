# Changelog

## v2.1.0

- Add ARM64 and Linux ARM binary selection.
- Add `system` version selection for a runner-installed ShellCheck.
- Add newline-separated `scandir` and `only_files` inputs.
- Add `files_list` output while preserving the existing `files` output.
- Add path-aware `additional_files` patterns and optional file symlink checks.
- Add GitHub annotations for GCC output and support extensionless scripts with custom shebangs.
- Move ShellCheck downloads to the runner temporary directory and validate action inputs.
