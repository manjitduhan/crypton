#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Reproducible build helper for strongSwan — running from: $ROOT_DIR"

missing=()
required=(perl make gcc pkg-config python3 autoconf automake libtool)
for cmd in "${required[@]}"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if [ ${#missing[@]} -ne 0 ]; then
  echo "Warning: the following required commands are missing: ${missing[*]}"
  if command -v apt >/dev/null 2>&1 || command -v apt-get >/dev/null 2>&1; then
    echo "On Debian/Ubuntu try: sudo apt update && sudo apt install build-essential autoconf automake libtool pkg-config perl python3"
  elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    echo "On Fedora/CentOS try: sudo dnf install make automake autoconf libtool gcc pkgconfig perl python3"
  else
    echo "Please install the missing packages for your distribution: ${missing[*]}"
  fi
  echo
fi

ASN1_DIR=build/strongswan/source/src/libstrongswan/asn1
if [ ! -f "$ASN1_DIR/oid.h" ] || [ ! -f "$ASN1_DIR/oid.c" ]; then
  if [ -f "$ASN1_DIR/oid.pl" ]; then
    echo "Generating ASN.1 sources with oid.pl..."
    pushd "$ASN1_DIR" >/dev/null
    perl oid.pl
    popd >/dev/null
    echo "Generated: $ASN1_DIR/oid.h and oid.c"
  else
    echo "ASN.1 generator not found at $ASN1_DIR/oid.pl — ensure you ran configure or that sources are present."
  fi
else
  echo "ASN.1 sources already present: $ASN1_DIR/oid.h"
fi

# Build strongswan
BUILD_DIR=build/strongswan
if [ ! -d "$BUILD_DIR" ]; then
  echo "Build directory $BUILD_DIR not found — run the project's configure/buildprep steps first." >&2
  exit 1
fi

echo "Running top-level make in $BUILD_DIR"
set +e
make -C "$BUILD_DIR" -j"$(nproc)"
rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo "Top-level make failed; attempting targeted builds to resolve ordering issues..."
  echo "Building vici plugin..."
  make -C "$BUILD_DIR/src/libcharon/plugins/vici" -j1 || true
  echo "Retrying top-level build..."
  make -C "$BUILD_DIR" -j"$(nproc)"
fi

echo
echo "Build finished. Key artifacts:" 
ls -la "$BUILD_DIR/src/libcharon/plugins/vici/libvici.la" || true
ls -la "$BUILD_DIR/src/libcharon/plugins/vici/.libs" || true
ls -la "$BUILD_DIR/src/swanctl/swanctl" || true

cat <<'EOF'

Runtime notes for strongMan:
- Set CRYPTON_STRONGMAN_ALLOWED_HOSTS to a comma-separated list of hosts before starting the Django app,
  e.g. export CRYPTON_STRONGMAN_ALLOWED_HOSTS="127.0.0.1,192.168.1.10"
- Ensure your virtualenv has the project's Python deps installed.

EOF
