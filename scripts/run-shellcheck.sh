#!/usr/bin/env bash
set -euo pipefail
set -f

fail() {
  printf '::error::%s\n' "$1" >&2
  exit 1
}

case "${INPUT_FORMAT:-gcc}" in
  checkstyle|diff|gcc|json|json1|quiet|tty) ;;
  *) fail "Unsupported ShellCheck output format." ;;
esac

case "${INPUT_SEVERITY:-}" in
  ""|error|warning|info|style) ;;
  *) fail "Unsupported ShellCheck severity." ;;
esac

case "${INPUT_ALL_SCRIPTS:-false}" in
  true|false) ;;
  *) fail "The all_scripts input must be true or false." ;;
esac

case "${INPUT_IGNORE_SYMLINKS:-true}" in
  true|false) ;;
  *) fail "The ignore_symlinks input must be true or false." ;;
esac

case "${INPUT_DISABLE_MATCHER:-false}" in
  true|false) ;;
  *) fail "The disable_matcher input must be true or false." ;;
esac

shellcheck_version="${INPUT_VERSION:-stable}"
shellcheck_bin=""
case "$shellcheck_version" in
  system)
    shellcheck_bin="$(command -v shellcheck || true)"
    [[ -n "$shellcheck_bin" ]] || fail "The system ShellCheck binary was not found in PATH."
    ;;
  *)
    if [[ "$shellcheck_version" != stable && ! "$shellcheck_version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
      fail "Use stable or a ShellCheck release version such as v0.11.0."
    fi

    case "${RUNNER_OS:-}" in
      Linux) shellcheck_os="linux" ;;
      macOS) shellcheck_os="darwin" ;;
      *) fail "ShellCheck binaries are supported on Linux and macOS runners." ;;
    esac

    runner_arch="${RUNNER_ARCH:-$(uname -m)}"
    case "$runner_arch" in
      X64|x86_64|amd64) shellcheck_arch="x86_64" ;;
      ARM64|aarch64|arm64) shellcheck_arch="aarch64" ;;
      ARM|armv6l|armv7l|armhf)
        [[ "$shellcheck_os" == linux ]] || fail "32-bit ARM ShellCheck binaries are available only for Linux."
        shellcheck_arch="armv6hf"
        ;;
      *) fail "This runner architecture has no supported ShellCheck binary." ;;
    esac

    asset_version="$shellcheck_version"
    if [[ "$asset_version" != stable && "$asset_version" != v* ]]; then
      asset_version="v$asset_version"
    fi
    release_ref="$asset_version"

    cache_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/action-shellcheck-cache/${asset_version}-${shellcheck_os}-${shellcheck_arch}"
    shellcheck_bin="$cache_dir/shellcheck"
    if [[ ! -x "$shellcheck_bin" ]]; then
      mkdir -p "$cache_dir" || fail "Could not create a temporary directory for ShellCheck."
      archive_path="$cache_dir/shellcheck.tar.xz"
      archive_url="https://github.com/koalaman/shellcheck/releases/download/${release_ref}/shellcheck-${asset_version}.${shellcheck_os}.${shellcheck_arch}.tar.xz"
      curl --fail --location --silent --show-error --retry 3 "$archive_url" --output "$archive_path" || fail "Could not download the requested ShellCheck release for this runner."
      tar -xf "$archive_path" -C "$cache_dir" || fail "Could not extract the ShellCheck release archive."
      extracted_binary="$cache_dir/shellcheck-${asset_version}/shellcheck"
      [[ -x "$extracted_binary" ]] || fail "The ShellCheck release archive did not contain an executable binary."
      mv "$extracted_binary" "$shellcheck_bin" || fail "Could not prepare the ShellCheck binary."
      rm -rf "$cache_dir/shellcheck-${asset_version}" "$archive_path"
    fi
    ;;
esac

"$shellcheck_bin" --version

shellcheck_args=()
if [[ -n "${INPUT_SEVERITY:-}" ]]; then
  shellcheck_args+=(-S "$INPUT_SEVERITY")
fi
shellcheck_args+=("--format=${INPUT_FORMAT:-gcc}")

if [[ -n "${SHELLCHECK_OPTS:-}" ]]; then
  extra_options=()
  extra_options_input="${SHELLCHECK_OPTS//$'\r'/}"
  extra_options_input="${extra_options_input//$'\n'/ }"
  read -r -a extra_options <<< "$extra_options_input"
  shellcheck_args+=("${extra_options[@]}")
fi

options_output=""
if [[ -n "${INPUT_SEVERITY:-}" ]]; then
  options_output="-S ${INPUT_SEVERITY}"
fi
if [[ -n "$options_output" ]]; then
  options_output+=" "
fi
options_output+="--format=${INPUT_FORMAT:-gcc}"

filepaths=()
ignore_path_patterns=()
ignore_name_patterns=()
additional_patterns=()
scan_dirs=()
candidate_file=""
matcher_active="false"
stop_token=""

# shellcheck disable=SC2329
cleanup() {
  if [[ -n "$stop_token" ]]; then
    printf '::%s::\n' "$stop_token"
    stop_token=""
  fi
  if [[ "$matcher_active" == true ]]; then
    printf '::remove-matcher owner=shellcheck-gcc::\n'
    printf '::remove-matcher owner=shellcheck-gcc-notice::\n'
    matcher_active="false"
  fi
  if [[ -n "$candidate_file" ]]; then
    rm -f "$candidate_file"
  fi
}
trap cleanup EXIT

is_ignored() {
  local candidate="$1"
  local basename="${candidate##*/}"
  local pattern
  local rule
  local path_patterns=()

  case "$candidate" in
    */.git/*|.git/*|*.go|*/mvnw|mvnw) return 0 ;;
  esac

  for rule in "${ignore_name_patterns[@]}"; do
    # shellcheck disable=SC2254
    case "$basename" in
      $rule) return 0 ;;
    esac
  done

  for rule in "${ignore_path_patterns[@]}"; do
    rule="${rule#./}"
    path_patterns=("$rule" "./$rule" "$rule/*" "./$rule/*" "*/$rule" "*/$rule/*")
    for pattern in "${path_patterns[@]}"; do
      # shellcheck disable=SC2254
      case "$candidate" in
        $pattern) return 0 ;;
      esac
    done
  done

  return 1
}

add_candidate() {
  local candidate="$1"
  local existing

  [[ -f "$candidate" ]] || return 0
  if [[ "${INPUT_IGNORE_SYMLINKS:-true}" == true && -L "$candidate" ]]; then
    return 0
  fi
  is_ignored "$candidate" && return 0
  [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]] || fail "File paths containing line breaks are not supported."

  for existing in "${filepaths[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  filepaths+=("$candidate")
}

if [[ -n "${INPUT_IGNORE:-}" ]]; then
  ignore_paths_input="$INPUT_IGNORE"
else
  ignore_paths_input="${INPUT_IGNORE_PATHS:-}"
fi
ignore_paths_input="${ignore_paths_input//$'\r'/}"
ignore_paths_input="${ignore_paths_input//$'\n'/ }"
read -r -a ignore_path_patterns <<< "$ignore_paths_input"

ignore_names_input="${INPUT_IGNORE_NAMES:-}"
ignore_names_input="${ignore_names_input//$'\r'/}"
ignore_names_input="${ignore_names_input//$'\n'/ }"
read -r -a ignore_name_patterns <<< "$ignore_names_input"

additional_files_input="${INPUT_ADDITIONAL_FILES:-}"
additional_files_input="${additional_files_input//$'\r'/}"
additional_files_input="${additional_files_input//$'\n'/ }"
read -r -a additional_patterns <<< "$additional_files_input"

if [[ -n "${INPUT_ONLY_FILES:-}" ]]; then
  while IFS= read -r file || [[ -n "$file" ]]; do
    file="${file%$'\r'}"
    [[ -n "$file" ]] || continue
    add_candidate "$file"
  done <<< "$INPUT_ONLY_FILES"
else
  raw_scandir="${INPUT_SCANDIR:-.}"
  while IFS= read -r directory || [[ -n "$directory" ]]; do
    directory="${directory%$'\r'}"
    [[ -n "$directory" ]] || continue

    directory_seen="false"
    for existing in "${scan_dirs[@]}"; do
      if [[ "$existing" == "$directory" ]]; then
        directory_seen="true"
        break
      fi
    done
    [[ "$directory_seen" == true ]] && continue
    [[ -d "$directory" ]] || fail "A scandir entry is not an existing directory."
    scan_dirs+=("$directory")
  done <<< "$raw_scandir"

  ((${#scan_dirs[@]} > 0)) || fail "At least one scandir directory is required."

  file_terms=(
    -name '*.bash'
    -o -name '.bashrc'
    -o -name 'bashrc'
    -o -name '.bash_aliases'
    -o -name '.bash_completion'
    -o -name '.bash_login'
    -o -name '.bash_logout'
    -o -name '.bash_profile'
    -o -name 'bash_profile'
    -o -name '*.ksh'
    -o -name 'suid_profile'
    -o -name '*.zsh'
    -o -name '.zlogin'
    -o -name 'zlogin'
    -o -name '.zlogout'
    -o -name 'zlogout'
    -o -name '.zprofile'
    -o -name 'zprofile'
    -o -name '.zsenv'
    -o -name 'zsenv'
    -o -name '.zshrc'
    -o -name 'zshrc'
    -o -name '*.sh'
    -o -path '*/.profile'
    -o -path '*/profile'
    -o -name '*.shlib'
  )

  for pattern in "${additional_patterns[@]}"; do
    file_terms+=(-o)
    if [[ "$pattern" == */* ]]; then
      file_terms+=(-path "*$pattern")
    else
      file_terms+=(-name "*$pattern")
    fi
  done

  candidate_file="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/action-shellcheck-files.XXXXXX")" || fail "Could not create a temporary file list."

  for directory in "${scan_dirs[@]}"; do
    find_directory="$directory"
    [[ "$find_directory" == -* ]] && find_directory="./$find_directory"

    if [[ "${INPUT_IGNORE_SYMLINKS:-true}" == true ]]; then
      find_type=(-type f)
    else
      find_type=(-type f -o -type l)
    fi

    if ! find "$find_directory" \
      ! -path '*/.git/*' \
      ! -path '*.go' \
      ! -path '*/mvnw' \
      \( "${find_type[@]}" \) \
      \( "${file_terms[@]}" \) \
      -print0 >> "$candidate_file"; then
      fail "Could not scan a configured directory."
    fi
  done

  while IFS= read -r -d '' file; do
    add_candidate "$file"
  done < "$candidate_file"

  for directory in "${scan_dirs[@]}"; do
    find_directory="$directory"
    [[ "$find_directory" == -* ]] && find_directory="./$find_directory"
    if [[ "${INPUT_IGNORE_SYMLINKS:-true}" == true ]]; then
      find_type=(-type f)
    else
      find_type=(-type f -o -type l)
    fi
    if ! find "$find_directory" \
      ! -path '*/.git/*' \
      ! -path '*.go' \
      ! -path '*/mvnw' \
      \( "${find_type[@]}" \) \
      ! -name '*.*' \
      -print0 >> "$candidate_file"; then
      fail "Could not scan a configured directory."
    fi
  done

  while IFS= read -r -d '' file; do
    [[ -f "$file" && -x "$file" ]] || continue
    is_ignored "$file" && continue
    IFS= read -r first_line < "$file" || true
    [[ "$first_line" == '#!'* ]] || continue
    if [[ "${INPUT_ALL_SCRIPTS:-false}" == true || "$first_line" =~ ^\#![[:space:]]*/[^[:space:]]*/(env[[:space:]]+)?[abk]*sh([[:space:]]|$) ]]; then
      add_candidate "$file"
    fi
  done < "$candidate_file"
fi

shellcheck_paths=()
for file in "${filepaths[@]}"; do
  case "$file" in
    /*|./*) shellcheck_paths+=("$file") ;;
    *) shellcheck_paths+=("./$file") ;;
  esac
done

files_output=""
for file in "${filepaths[@]}"; do
  safe_file="${file//'%'/'%25'}"
  safe_file="${safe_file//$'\r'/'%0D'}"
  safe_file="${safe_file//$'\n'/'%0A'}"
  if [[ -n "$files_output" ]]; then
    files_output+=" "
  fi
  files_output+="$safe_file"
done

output_file="${GITHUB_OUTPUT:-/dev/null}"
printf 'files=%s\n' "$files_output" >> "$output_file"
printf 'options=%s\n' "$options_output" >> "$output_file"

delimiter="SHELLCHECK_FILES_$$"
while true; do
  delimiter_found="false"
  for file in "${filepaths[@]}"; do
    if [[ "$file" == *"$delimiter"* ]]; then
      delimiter_found="true"
      break
    fi
  done
  [[ "$delimiter_found" == false ]] && break
  delimiter+="_X"
done
{
  printf 'files_list<<%s\n' "$delimiter"
  for file in "${filepaths[@]}"; do
    printf '%s\n' "$file"
  done
  printf '%s\n' "$delimiter"
} >> "$output_file"

statuscode=0
if ((${#filepaths[@]} == 0)); then
  printf 'No shell scripts matched the selected paths.\n'
else
  matcher_file="${ACTION_PATH:-.}/.github/problem-matcher-gcc.json"
  if [[ "${INPUT_FORMAT:-gcc}" == gcc && "${INPUT_DISABLE_MATCHER:-false}" != true && -f "$matcher_file" ]]; then
    printf '::add-matcher::%s\n' "$matcher_file"
    matcher_active="true"
  fi

  stop_token="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')"
  [[ -n "$stop_token" ]] || fail "Could not generate a workflow command stop token."
  printf '::stop-commands::%s\n' "$stop_token"

  if [[ "${INPUT_CHECK_TOGETHER:-false}" == true || "${INPUT_CHECK_TOGETHER:-}" == yes ]]; then
    if "$shellcheck_bin" "${shellcheck_args[@]}" -- "${shellcheck_paths[@]}" 2>&1; then
      statuscode=0
    else
      statuscode=$?
    fi
  else
    for file in "${shellcheck_paths[@]}"; do
      if "$shellcheck_bin" "${shellcheck_args[@]}" -- "$file" 2>&1; then
        :
      else
        file_status=$?
        [[ "$statuscode" != 0 ]] || statuscode="$file_status"
      fi
    done
  fi

  printf '::%s::\n' "$stop_token"
  stop_token=""
  if [[ "$matcher_active" == true ]]; then
    printf '::remove-matcher owner=shellcheck-gcc::\n'
    printf '::remove-matcher owner=shellcheck-gcc-notice::\n'
    matcher_active="false"
  fi
fi

printf 'statuscode=%s\n' "$statuscode" >> "$output_file"
exit "$statuscode"
