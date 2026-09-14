#!/usr/bin/env bash
set -Eeuo pipefail

# Standalone target-side installer.
#
# This file is copied into crypton_installer.tar by crypton_export.sh. It is
# intentionally independent from the Crypton repository: after the outer
# archive is unpacked, this script only needs crypton_package.tar beside it.
# The package uses filesystem-relative paths (usr/, etc/, opt/, and var/), so
# --root / installs into the normal host filesystem and another root can be
# used for image assembly or a chroot.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
PACKAGE="$SCRIPT_DIR/crypton_package.tar"
MANIFEST="$SCRIPT_DIR/manifest"
ROOT=/
DRY_RUN=0

die() { printf 'crypton installer: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'crypton installer: %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./crypton_install.sh [options]

Install crypton_package.tar from the same directory.

Options:
  --root PATH    Install below PATH (default: /)
  --dry-run      Show the package contents without changing the target
  -h, --help     Show this help
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --root)
      (( $# >= 2 )) || die '--root requires a path'
      ROOT=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$ROOT" == /* ]] || die '--root must be an absolute path'
[[ -f "$PACKAGE" ]] || die "package not found beside installer: $PACKAGE"
command -v tar >/dev/null 2>&1 || die 'tar is required on the target host'

# The package is architecture-specific. Refuse an obviously incompatible
# target before writing anything; a 64-bit ARM package must not be installed
# on a 32-bit ARM userspace.
if [[ -f "$MANIFEST" ]]; then
  package_arch=$(awk -F= '$1 == "architecture" { print $2; exit }' "$MANIFEST")
  target_arch=$(uname -m)
  case "$package_arch:$target_arch" in
    aarch64:arm64|arm64:aarch64|"$target_arch:$target_arch") ;;
    *) die "package architecture '$package_arch' is not compatible with target '$target_arch'" ;;
  esac
fi

# Reject unsafe archive members before extraction. The exporter creates a
# root filesystem archive, so absolute paths and parent traversal are never
# valid package content.
while IFS= read -r member; do
  case "$member" in
    /*|../*|*/../*|*/..|.) die "unsafe package member: $member" ;;
  esac
done < <(tar -tf "$PACKAGE")

if (( DRY_RUN == 1 )); then
  info "would install below $ROOT"
  tar -tf "$PACKAGE"
  exit 0
fi

if [[ "$ROOT" == / && "$EUID" -ne 0 ]]; then
  die 'installing into / requires root; use sudo or pass --root for a staging directory'
fi

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/crypton-install.XXXXXX")
cleanup() { rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT

tar -xf "$PACKAGE" -C "$TEMP_DIR"
for top_level in etc opt run usr var; do
  [[ -e "$TEMP_DIR/$top_level" ]] || continue
  mkdir -p "$ROOT/$top_level"
  # Preserve modes, symlinks, and directory structure from the package while
  # leaving unrelated files in the target filesystem untouched.
  cp -a "$TEMP_DIR/$top_level/." "$ROOT/$top_level/"
done

# Refresh the dynamic linker cache when installing to the live root. This is
# best-effort because image roots may not contain ldconfig yet; the installer
# still succeeds for those roots and the target boot process can refresh it.
if [[ "$ROOT" == / ]] && command -v ldconfig >/dev/null 2>&1; then
  ldconfig || info 'ldconfig could not refresh the host cache; run it manually'
fi

info "installation completed below $ROOT"
