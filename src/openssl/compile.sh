#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# Configure and install OpenSSL into its isolated workspace prefix. The
# libraries list is intentionally read from this project's configure.yaml.
build() {
  local library library_count=0 static=0 shared=0 target_prefix ssl_dir
  local -a configure_args
  checkout_project
  target_prefix=$(config_value target_prefix); target_prefix=${target_prefix:-/usr}
  ssl_dir=$(config_value ssl_dir); ssl_dir=${ssl_dir:-/etc/ssl/crypton}
  [[ "$target_prefix" == /* && "$ssl_dir" == /* ]] || die 'target_prefix and ssl_dir must be absolute paths'
  # Build for the target filesystem, then stage the installation below the
  # project output directory. This removes workspace-specific paths from the
  # binaries and makes the output suitable for crypton export.
  configure_args=(--prefix="$target_prefix" --libdir=lib --openssldir="$ssl_dir" no-tests)
  while IFS= read -r library; do
    [[ -n "$library" ]] || continue
    case "$library" in
      static) static=1 ;;
      shared) shared=1 ;;
      *) die "invalid OpenSSL library type: $library" ;;
    esac
    library_count=$((library_count + 1))
  done < <(config_items libraries)
  # Preserve the simple historical default: static-only when no list exists.
  (( library_count > 0 )) || static=1
  (( static == 1 )) || die 'OpenSSL shared-only builds are not supported; include static and shared'
  if (( shared == 1 )); then configure_args+=(shared); else configure_args+=(no-shared); fi
  # Configure and compile in the isolated build tree; create it explicitly
  # because the source checkout and install prefix are separate directories.
  mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
  # Remove installed artifacts from an older library-mode configuration while
  # retaining the output directory itself.
  for subdir in usr etc; do rm -rf -- "$OUTPUT_DIR/$subdir"; done
  rm -f "$BUILD_DIR/Makefile"
  (cd "$BUILD_DIR" && "$SOURCE_DIR/Configure" "${configure_args[@]}" "$@")
  (cd "$BUILD_DIR" && make -j"$JOBS")
  (cd "$BUILD_DIR" && make install_sw install_ssldirs DESTDIR="$OUTPUT_DIR")
  info "built into $OUTPUT_DIR"
}

openssl_binary() {
  local binary="$OUTPUT_DIR/usr/bin/openssl"
  [[ -x "$binary" ]] || die 'OpenSSL is not built; run ./crypton build openssl'
  printf '%s\n' "$binary"
}

run() {
  # With no arguments, report the isolated OpenSSL version; otherwise pass the
  # caller's arguments to the isolated binary.
  local binary library_path="$OUTPUT_DIR/usr/lib"
  binary=$(openssl_binary)
  LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary" "${@:-version}"
}

require_project_config
command=${1:-build}; shift || true
case "$command" in
  build|compile) build "$@" ;;
  run) run "$@" ;;
  clean) clean_project ;;
  clean-sources) [[ "${1:-}" == --force ]] && clean_sources 1 || clean_sources ;;
  *) die "unknown command '$command' (use build, run, clean, or clean-sources)" ;;
esac
