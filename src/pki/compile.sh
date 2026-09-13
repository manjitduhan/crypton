#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# PKI is an internal project: it does not compile a third-party source tree.
# Its build step validates the declarative PKI file, while its runtime commands
# invoke the OpenSSL executable from the independent OpenSSL project.
build() {
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for the PKI project'
  python3 "$PROJECT_DIR/pki.py" --config "$PROJECT_DIR/pki.json" validate
  info 'PKI configuration validated'
}

run() {
  local config="$PROJECT_DIR/pki.json"
  command -v python3 >/dev/null 2>&1 || die 'python3 is required for the PKI project'
  # `crypton run pki ...` enters this function with the subcommand as its
  # first argument. Route bundle installation to the dependency-free helper;
  # all other PKI commands use the JSON-aware manager.
  case "${1:-}" in
    install-bundle|installer)
      shift
      install_bundle "$@"
      ;;
    *)
      CRYPTON_OPENSSL_BIN="${CRYPTON_OPENSSL_BIN:-$OUTPUT_ROOT/openssl/bin/openssl}" \
        python3 "$PROJECT_DIR/pki.py" --config "$config" "$@"
      ;;
  esac
}

install_bundle() {
  # Keep bundle installation as a separate script so it can also be copied
  # and used on a target machine without parsing the PKI YAML configuration.
  exec "$PROJECT_DIR/pki_installer" "$@"
}

require_project_config
command=${1:-build}; shift || true
case "$command" in
  build|compile) build "$@" ;;
  run|certmgr|pki) run "$@" ;;
  install-bundle|installer) install_bundle "$@" ;;
  clean)
    # PKI output is valuable material and is never removed implicitly by the
    # project clean command. Use `pki generate --force` to replace one tree.
    info 'PKI output was preserved; certificate material requires explicit cleanup'
    ;;
  *) die "unknown command '$command' (use build, run, install-bundle, or clean)" ;;
esac
