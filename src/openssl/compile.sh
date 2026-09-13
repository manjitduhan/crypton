#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# Configure and install OpenSSL into its isolated workspace prefix. The
# libraries list is intentionally read from this project's configure.yaml.
build() {
  local library library_count=0 static=0 shared=0
  local -a configure_args=(--prefix="$OUTPUT_DIR" --openssldir="$OUTPUT_DIR/ssl" no-tests "-Wl,-rpath,$OUTPUT_DIR/lib")
  checkout_project
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
  for subdir in lib lib64 include/openssl bin ssl; do rm -rf -- "$OUTPUT_DIR/$subdir"; done
  rm -f "$BUILD_DIR/Makefile"
  (cd "$BUILD_DIR" && "$SOURCE_DIR/Configure" "${configure_args[@]}" "$@")
  (cd "$BUILD_DIR" && make -j"$JOBS")
  (cd "$BUILD_DIR" && make install_sw install_ssldirs)
  info "built into $OUTPUT_DIR"
}

run() {
  # With no arguments, report the isolated OpenSSL version; otherwise pass the
  # caller's arguments to the isolated binary.
  [[ -x "$OUTPUT_DIR/bin/openssl" ]] || die 'OpenSSL is not built; run ./crypton build openssl'
  "$OUTPUT_DIR/bin/openssl" "${@:-version}"
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
