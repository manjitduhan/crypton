#!/usr/bin/env bash
set -Eeuo pipefail

# Assemble already-built projects into a deployable filesystem package. This
# is workspace-side packaging only. The target-side installation logic lives
# in crypton_install.sh and is copied into the outer archive.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
WORKSPACE_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
OUTPUT_ROOT="${CRYPTON_OUTPUT_ROOT:-$WORKSPACE_ROOT/output}"
DEFAULT_OUTPUT="$OUTPUT_ROOT/crypton_installer"
INSTALLER_TEMPLATE="$SCRIPT_DIR/crypton_install.sh"
PROJECTS=(openssl openssh strongswan strongman)

die() { printf 'crypton export: error: %s\n' "$*" >&2; exit 1; }
info() { printf 'crypton export: %s\n' "$*"; }

usage() {
  cat <<'EOF'
Usage: ./crypton export [all] [--output PATH]

Create an outer deployment archive containing:
  crypton_package.tar   filesystem package for all built runtime projects
  crypton_install.sh    standalone target-side installer
  manifest              package metadata
EOF
}

OUTPUT_PATH="$DEFAULT_OUTPUT"
while (( $# > 0 )); do
  case "$1" in
    all) shift ;;
    --output)
      (( $# >= 2 )) || die '--output requires a directory'
      OUTPUT_PATH=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -x "$INSTALLER_TEMPLATE" ]] || die "installer is not executable: $INSTALLER_TEMPLATE"
mkdir -p "$OUTPUT_PATH"

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/crypton-export.XXXXXX")
cleanup() { rm -rf -- "$STAGING"; }
trap cleanup EXIT
mkdir -p "$STAGING/etc" "$STAGING/opt" "$STAGING/run/crypton/strongswan" \
  "$STAGING/run/crypton/openssh" "$STAGING/usr" "$STAGING/var/log/crypton/strongswan"

copy_tree() {
  local source=$1 target=$2
  [[ -e "$source" ]] || return 0
  mkdir -p "$target"
  cp -a "$source/." "$target/"
}

copy_prefix() {
  local project=$1 source="$OUTPUT_ROOT/$1" directory
  [[ -d "$source" ]] || die "$project is not built: run ./crypton build $project"
  # New builds are staged as a target root (usr/, etc/, and so on). Accepting
  # the old prefix shape as a fallback keeps the exporter useful while an
  # existing workspace is rebuilt.
  if [[ -d "$source/usr" ]]; then
    copy_tree "$source/usr" "$STAGING/usr"
    return
  fi
  # Conventional project prefixes are staged below /usr in the package. The
  # package therefore installs into /usr/bin, /usr/lib, and related paths.
  for directory in bin sbin lib lib64 libexec share include; do
    [[ -e "$source/$directory" ]] || continue
    case "$directory" in
      lib64) copy_tree "$source/$directory" "$STAGING/usr/lib" ;;
      *) copy_tree "$source/$directory" "$STAGING/usr/$directory" ;;
    esac
  done
}

# Compiled projects share the normal target filesystem locations. Dependency
# inclusion is intentional: strongSwan and OpenSSH need the bundled OpenSSL.
copy_prefix openssl
copy_prefix openssh
copy_prefix strongswan

# Configuration is kept out of /usr and mapped to stable project locations.
copy_tree "$OUTPUT_ROOT/openssl/etc" "$STAGING/etc"
copy_tree "$OUTPUT_ROOT/openssl/ssl" "$STAGING/etc/ssl/crypton"
copy_tree "$OUTPUT_ROOT/openssh/etc/ssh" "$STAGING/etc/ssh"
copy_tree "$OUTPUT_ROOT/strongswan/etc/swanctl" "$STAGING/etc/swanctl"
if [[ -f "$OUTPUT_ROOT/strongswan/etc/strongswan.conf" ]]; then
  mkdir -p "$STAGING/etc/strongswan"
  cp -a "$OUTPUT_ROOT/strongswan/etc/strongswan.conf" "$STAGING/etc/strongswan/"
fi

# StrongMan is a Python application, so its source and virtual environment
# remain together under /opt. Runtime PID/log state is intentionally not
# copied into the package.
[[ -d "$OUTPUT_ROOT/strongman" ]] || die 'strongman is not built: run ./crypton build strongman'
copy_tree "$OUTPUT_ROOT/strongman/app" "$STAGING/opt/crypton/strongman/app"
copy_tree "$OUTPUT_ROOT/strongman/venv" "$STAGING/opt/crypton/strongman/venv"

# PKI output is deliberately excluded because it contains authority and device
# private keys. PKI bundles continue to use the separate pki_installer flow.
MANIFEST="$STAGING/manifest"
{
  printf 'format=crypton-filesystem-package-1\n'
  printf 'architecture=%s\n' "$(uname -m)"
  printf 'projects=%s\n' "${PROJECTS[*]}"
  printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'pki_private_keys=excluded\n'
} > "$MANIFEST"

rm -f -- "$OUTPUT_PATH/crypton_package.tar" "$OUTPUT_PATH/crypton_install.sh" \
  "$OUTPUT_PATH/manifest" "$OUTPUT_PATH/crypton_installer.tar"
tar -cf "$OUTPUT_PATH/crypton_package.tar" -C "$STAGING" --exclude='./manifest' .
cp -f "$INSTALLER_TEMPLATE" "$OUTPUT_PATH/crypton_install.sh"
chmod 0755 "$OUTPUT_PATH/crypton_install.sh"
cp -f "$MANIFEST" "$OUTPUT_PATH/manifest"

# The outer archive is the single artifact copied to the target. Its members
# stay together so the installer can find crypton_package.tar beside itself.
tar -cf "$OUTPUT_PATH/crypton_installer.tar" \
  -C "$OUTPUT_PATH" crypton_package.tar crypton_install.sh manifest
info "created $OUTPUT_PATH/crypton_installer.tar"
