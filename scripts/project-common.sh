#!/usr/bin/env bash
set -Eeuo pipefail

# Shared plumbing for project-owned compile scripts.
#
# A project script sources this file, receives its paths through environment
# variables when called by crypton, and reads only its own configure.yaml.
# Project scripts remain responsible for their build and runtime behavior.

# These values are exported by crypton for normal use. The fallbacks also let
# a project script be run directly during development.
PROJECT_DIR="${CRYPTON_PROJECT_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)}"
PROJECT_NAME="${CRYPTON_PROJECT_NAME:-$(basename -- "$PROJECT_DIR")}"
WORKSPACE_ROOT="${CRYPTON_ROOT:-$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd -P)}"
CONFIG_FILE="${CRYPTON_PROJECT_CONFIG:-$PROJECT_DIR/configure.yaml}"
SOURCE_DIR="${CRYPTON_SOURCE_DIR:-$PROJECT_DIR/source}"
BUILD_DIR="${CRYPTON_BUILD_DIR:-$WORKSPACE_ROOT/build/$PROJECT_NAME}"
OUTPUT_DIR="${CRYPTON_OUTPUT_DIR:-$WORKSPACE_ROOT/output/$PROJECT_NAME}"
OUTPUT_ROOT="${CRYPTON_OUTPUT_ROOT:-$WORKSPACE_ROOT/output}"
JOBS="${CRYPTON_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '2')}"

die() { printf '%s: error: %s\n' "$PROJECT_NAME" "$*" >&2; exit 1; }
info() { printf '%s: %s\n' "$PROJECT_NAME" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROJECT_NAME" "$*" >&2; }

require_file() { [[ -f "$1" ]] || die "file not found: $1"; }

# This intentionally supports the small YAML subset used by project configs.
# Keeping the parser here means projects do not need yq/PyYAML just to build.
# Values may contain inline comments and may be quoted with double quotes.
# Read a top-level scalar such as repo or version from this project's YAML.
config_value() {
  local key=$1
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*" {
      sub("^[^:]*:[[:space:]]*", "");
      sub(/[[:space:]]+#.*/, "");
      gsub(/^"|"$/, "");
      print; exit
    }
  ' "$CONFIG_FILE"
}

# Read a scalar from a two-space-indented section such as server or client.
config_section_value() {
  local section=$1 key=$2
  awk -v section="$section" -v key="$key" '
    $0 ~ "^" section ":[[:space:]]*$" { in_section=1; next }
    in_section && /^[^ #[:space:]][^:]*:/ { in_section=0 }
    in_section && $0 ~ "^  " key ":[[:space:]]*" {
      sub("^[^:]*:[[:space:]]*", "");
      sub(/[[:space:]]+#.*/, "");
      gsub(/^"|"$/, "");
      print; exit
    }
  ' "$CONFIG_FILE"
}

# Read a simple YAML list and return one item per line for shell loops.
config_items() {
  local key=$1
  awk -v key="$key" '
    $0 ~ "^" key ":[[:space:]]*$" { in_list=1; next }
    # A new top-level key ends the list.  This must not be limited to nested
    # map keys, otherwise a components list can accidentally
    # consume the following `plugins` list.
    in_list && /^[^[:space:]#][^:]*:/ { exit }
    in_list && /^  - / {
      sub(/^  - /, "");
      gsub(/^"|"$/, "");
      print; next
    }
  ' "$CONFIG_FILE"
}

checkout_project() {
  local repo version
  repo=$(config_value repo)
  version=$(config_value version)
  [[ -n "$repo" && -n "$version" ]] || die 'configure.yaml must define repo and version'
  mkdir -p "$(dirname -- "$SOURCE_DIR")"
  # Keep the downloaded checkout separate from build/output so it can be
  # reused and inspected without mixing in generated files.
  if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    info "cloning $PROJECT_NAME ($version)"
    git clone --branch "$version" --single-branch "$repo" "$SOURCE_DIR"
    return
  fi
  # Never overwrite local source edits during an automatic refresh.
  if [[ -n "$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all)" ]]; then
    die "$SOURCE_DIR has local changes; commit or remove them before rebuilding"
  fi
  info "updating $PROJECT_NAME ($version)"
  git -C "$SOURCE_DIR" fetch --tags --prune origin
  git -C "$SOURCE_DIR" checkout "$version"
}

prepare_build_dir() {
  mkdir -p "$BUILD_DIR"
  printf '%s' "$BUILD_DIR"
}

apply_project_patches() {
  local patch_path patch_name patch_root="$PROJECT_DIR/patches"
  [[ -d "$patch_root" ]] || return 0
  # Patches modify only the build copy. The upstream checkout stays clean and
  # can be refreshed from its remote on the next build.
  for patch_path in "$patch_root"/*.patch; do
    [[ -f "$patch_path" ]] || continue
    patch_name=$(basename -- "$patch_path")
    if ! (cd "$1" && patch --batch --forward --strip=1 < "$patch_path" >/dev/null); then
      die "failed to apply patch $patch_name"
    fi
    info "applied patch: $patch_name"
  done
}

clean_project() {
  # Generated trees are safe to recreate; source checkouts are intentionally
  # preserved by this command.
  [[ "$BUILD_DIR" != "$WORKSPACE_ROOT" && "$OUTPUT_DIR" != "$WORKSPACE_ROOT" ]] || die 'refusing to clean the workspace root'
  rm -rf -- "$BUILD_DIR" "$OUTPUT_DIR"
  info 'removed project build and output directories'
}

clean_sources() {
  [[ "$SOURCE_DIR" != "$PROJECT_DIR" && "$SOURCE_DIR" != / ]] || die 'refusing to remove an unsafe source path'
  [[ -e "$SOURCE_DIR" ]] || { info 'source checkout does not exist'; return; }
  local force=${1:-0} changes
  # Removing a checkout with uncommitted work requires an explicit --force.
  if [[ -d "$SOURCE_DIR/.git" && "$force" != 1 ]]; then
    changes=$(git -C "$SOURCE_DIR" status --porcelain --untracked-files=all || true)
    [[ -z "$changes" ]] || die "$SOURCE_DIR has local changes; use clean-sources ... --force to remove it"
  fi
  rm -rf -- "$SOURCE_DIR"
  info 'removed source checkout'
}

require_project_config() {
  require_file "$CONFIG_FILE"
  local configured_project
  configured_project=$(config_value project)
  [[ "$configured_project" == "$PROJECT_NAME" ]] || die "configure.yaml project must be '$PROJECT_NAME'"
}
