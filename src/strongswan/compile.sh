#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# Convert a project-local relative path to a workspace path. Absolute paths
# are left untouched so a project can use an external prefix or toolchain.
project_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$WORKSPACE_ROOT" "${1#./}" ;;
  esac
}

# Build strongSwan using the small set of options that matters to this
# project. The plugin list, install prefix, and compiler toolchain are kept in
# src/strongswan/configure.yaml.
build() {
  local prefix_path toolchain_path openssl_prefix plugin
  local project_cppflags project_ldflags
  local -a configure_args

  checkout_project

  prefix_path=$(config_value prefix_path)
  prefix_path=$(project_path "${prefix_path:-output/strongswan}")
  toolchain_path=$(config_value toolchain_path)
  toolchain_path=${toolchain_path:-/usr/bin}
  openssl_prefix="$OUTPUT_ROOT/openssl"

  [[ -d "$toolchain_path" ]] || die "compiler toolchain directory not found: $toolchain_path"
  [[ -d "$openssl_prefix/include" && -d "$openssl_prefix/lib" ]] || die "OpenSSL bundle not found: $openssl_prefix"
  OUTPUT_DIR="$prefix_path"

  # strongSwan's repository provides autogen.sh. It runs autoreconf and
  # creates the configure script in the source checkout; generated files are
  # ignored by the upstream repository.
  if [[ -x "$SOURCE_DIR/autogen.sh" ]]; then
    (cd "$SOURCE_DIR" && PATH="$toolchain_path:$PATH" ./autogen.sh)
  elif [[ ! -x "$SOURCE_DIR/configure" ]]; then
    command -v autoreconf >/dev/null 2>&1 || die 'autoreconf is required to build strongSwan'
    (cd "$SOURCE_DIR" && PATH="$toolchain_path:$PATH" autoreconf -fi)
  fi
  [[ -x "$SOURCE_DIR/configure" ]] || die 'strongSwan configure script was not generated'

  mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
  project_cppflags="-I$openssl_prefix/include${CPPFLAGS:+ $CPPFLAGS}"
  project_ldflags="-L$openssl_prefix/lib${LDFLAGS:+ $LDFLAGS}"
  configure_args=(
    --prefix="$OUTPUT_DIR"
    --sysconfdir="$OUTPUT_DIR/etc"
    --with-piddir="$OUTPUT_DIR/var/run"
    --disable-defaults
    --disable-stroke
    --enable-charon
    --enable-swanctl
  )

  # --disable-defaults makes this list authoritative. Validate names before
  # turning them into configure options so a YAML typo fails clearly.
  while IFS= read -r plugin; do
    [[ "$plugin" =~ ^[a-zA-Z0-9_-]+$ ]] || die "invalid plugin name: $plugin"
    configure_args+=("--enable-$plugin")
  done < <(config_items plugins)

  # Build from a separate tree, then install directly into the project prefix.
  # Serial make avoids the missing libvici.la ordering issue in some
  # strongSwan/Automake releases and keeps this flow deterministic.
  (
    cd "$BUILD_DIR"
    PATH="$toolchain_path:$PATH" \
    CPPFLAGS="$project_cppflags" \
    LDFLAGS="$project_ldflags" \
      "$SOURCE_DIR/configure" "${configure_args[@]}" "$@"
  )
  make -C "$BUILD_DIR" -j1
  make -C "$BUILD_DIR" install
  info "built into $OUTPUT_DIR"
}

require_project_config
command=${1:-build}; shift || true
case "$command" in
  build|compile) build "$@" ;;
  # Runtime behavior is kept separate from the build procedure.
  run|stop) exec "$PROJECT_DIR/run.sh" "$command" "$@" ;;
  clean) clean_project ;;
  clean-sources) [[ "${1:-}" == --force ]] && clean_sources 1 || clean_sources ;;
  *) die "unknown command '$command' (use build, run, stop, clean, or clean-sources)" ;;
esac
