#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# Build OpenSSH against the isolated OpenSSL installation. Client/server
# behavior is configured in this project's configure.yaml.
build() {
  local source_dir="$SOURCE_DIR" generated_source target_prefix sysconfdir privsep_path pid_dir
  local openssl_prefix
  local -a configure_args
  checkout_project
  target_prefix=$(config_value target_prefix); target_prefix=${target_prefix:-/usr}
  sysconfdir=$(config_value sysconfdir); sysconfdir=${sysconfdir:-/etc/ssh}
  privsep_path=$(config_value privsep_path); privsep_path=${privsep_path:-/var/empty}
  pid_dir=$(config_value pid_dir); pid_dir=${pid_dir:-/run/crypton/openssh}
  [[ "$target_prefix" == /* && "$sysconfdir" == /* && "$privsep_path" == /* && "$pid_dir" == /* ]] \
    || die 'OpenSSH target paths must be absolute'
  [[ -x "$source_dir/configure" || -f "$source_dir/configure.ac" ]] || die 'OpenSSH requires configure or configure.ac'
  mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
  # Generate autotools files in build/source when the upstream checkout needs
  # it, keeping the reusable source checkout untouched.
  if [[ ! -x "$source_dir/configure" || "$source_dir/configure.ac" -nt "$source_dir/configure" ]]; then
    generated_source="$BUILD_DIR/source"
    rm -rf -- "$generated_source"
    mkdir -p "$generated_source"
    (cd "$source_dir" && git archive --format=tar HEAD) | tar -x -C "$generated_source"
    if [[ -x "$generated_source/autogen.sh" ]]; then
      (cd "$generated_source" && ./autogen.sh)
    else
      command -v autoreconf >/dev/null 2>&1 || die 'autoreconf is required to regenerate OpenSSH'
      (cd "$generated_source" && autoreconf -fi)
    fi
    source_dir="$generated_source"
  fi
  openssl_prefix="$OUTPUT_ROOT/openssl/usr"
  [[ -d "$openssl_prefix" ]] || die 'OpenSSL must be built before OpenSSH'
  # OpenSSH links against the staged OpenSSL installation. Both projects use
  # standard target paths, so the final package is not tied to this workspace.
  configure_args=(
    --prefix="$target_prefix"
    --sysconfdir="$sysconfdir"
    --with-ssl-dir="$openssl_prefix"
    --with-privsep-path="$privsep_path"
    --with-pid-dir="$pid_dir"
  )
  rm -rf -- "$OUTPUT_DIR/usr" "$OUTPUT_DIR/etc" "$OUTPUT_DIR/var"
  (cd "$BUILD_DIR" && LDFLAGS="-L$openssl_prefix/lib" "$source_dir/configure" "${configure_args[@]}" "$@")
  (cd "$BUILD_DIR" && make -j"$JOBS")
  (cd "$BUILD_DIR" && make install DESTDIR="$OUTPUT_DIR")
  info "built into $OUTPUT_DIR"
}

runtime_library_path() {
  printf '%s\n' "$OUTPUT_ROOT/openssl/usr/lib:$OUTPUT_DIR/usr/lib"
}

run_server() {
  # Validate and translate YAML server settings into sshd command-line options.
  local config="$OUTPUT_DIR/etc/ssh/sshd_config" runtime="$OUTPUT_DIR/run/crypton/openssh"
  local pid_path="$runtime/sshd.pid" log_path="$runtime/sshd.log"
  local port bind password_authentication kbd_interactive_authentication
  local pubkey_authentication permit_root_login permit_tty allow_tcp_forwarding
  local x11_forwarding use_dns banner kex_algorithms macs ciphers pid command_line attempt
  local -a options
  local library_path
  port=$(config_section_value server port); bind=$(config_section_value server bind)
  password_authentication=$(config_section_value server password_authentication)
  kbd_interactive_authentication=$(config_section_value server kbd_interactive_authentication)
  pubkey_authentication=$(config_section_value server pubkey_authentication)
  permit_root_login=$(config_section_value server permit_root_login)
  permit_tty=$(config_section_value server permit_tty)
  allow_tcp_forwarding=$(config_section_value server allow_tcp_forwarding)
  x11_forwarding=$(config_section_value server x11_forwarding)
  use_dns=$(config_section_value server use_dns)
  banner=$(config_section_value server banner)
  kex_algorithms=$(config_section_value server kex_algorithms)
  macs=$(config_section_value server macs); ciphers=$(config_section_value server ciphers)
  port=${port:-2224}; bind=${bind:-0.0.0.0}; password_authentication=${password_authentication:-no}
  kbd_interactive_authentication=${kbd_interactive_authentication:-no}; pubkey_authentication=${pubkey_authentication:-yes}
  permit_root_login=${permit_root_login:-no}; permit_tty=${permit_tty:-yes}; allow_tcp_forwarding=${allow_tcp_forwarding:-yes}
  x11_forwarding=${x11_forwarding:-no}; use_dns=${use_dns:-no}; banner=${banner:-none}
  kex_algorithms=${kex_algorithms:-default}; macs=${macs:-default}; ciphers=${ciphers:-default}
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] || die "invalid server port: $port"
  [[ -n "$bind" && "$bind" != *[[:space:]]* ]] || die "invalid server bind address: $bind"
  for value in "$password_authentication" "$kbd_interactive_authentication" "$pubkey_authentication" "$permit_tty" "$x11_forwarding" "$use_dns"; do
    [[ "$value" == yes || "$value" == no ]] || die "invalid yes/no server setting: $value"
  done
  case "$permit_root_login" in yes|no|prohibit-password) ;; *) die "invalid permit_root_login: $permit_root_login" ;; esac
  case "$allow_tcp_forwarding" in yes|no|all|local|remote) ;; *) die "invalid allow_tcp_forwarding: $allow_tcp_forwarding" ;; esac
  [[ -x "$OUTPUT_DIR/usr/sbin/sshd" ]] || die 'OpenSSH is not built; run ./crypton build openssh'
  [[ -f "$config" ]] || die "OpenSSH configuration not found: $config"
  if [[ "$banner" != none && "$banner" != /* ]]; then banner="$PROJECT_DIR/../../$banner"; fi
  [[ "$banner" == none || -f "$banner" ]] || die "OpenSSH banner file not found: $banner"
  mkdir -p "$runtime" "$OUTPUT_DIR/var/empty"
  options=(-p "$port" -o "ListenAddress=$bind" -o "PidFile=$pid_path"
    -o "PasswordAuthentication=$password_authentication" -o "KbdInteractiveAuthentication=$kbd_interactive_authentication"
    -o "PubkeyAuthentication=$pubkey_authentication" -o "PermitRootLogin=$permit_root_login"
    -o "PermitTTY=$permit_tty" -o "AllowTcpForwarding=$allow_tcp_forwarding"
    -o "X11Forwarding=$x11_forwarding" -o "UseDNS=$use_dns")
  [[ "$kex_algorithms" == default ]] || options+=(-o "KexAlgorithms=$kex_algorithms")
  [[ "$macs" == default ]] || options+=(-o "MACs=$macs")
  [[ "$ciphers" == default ]] || options+=(-o "Ciphers=$ciphers")
  [[ "$banner" == none ]] || options+=(-o "Banner=$banner")
  # Validate before stopping an existing daemon, so a bad edit does not take
  # down a working server.
  library_path=$(runtime_library_path)
  LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$OUTPUT_DIR/usr/sbin/sshd" -t -f "$config" "${options[@]}"
  # The configured server is a daemon; replace it only after validation.
  [[ -f "$pid_path" ]] && stop_server
  LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$OUTPUT_DIR/usr/sbin/sshd" -f "$config" "${options[@]}" -E "$log_path" "$@"
  for (( attempt = 0; attempt < 50; attempt++ )); do [[ -s "$pid_path" ]] && break; sleep 0.1; done
  [[ -s "$pid_path" ]] || die "OpenSSH failed to start; see $log_path"
  pid=$(head -n 1 "$pid_path"); [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid OpenSSH PID file: $pid_path"
  kill -0 "$pid" 2>/dev/null || die "OpenSSH exited during startup; see $log_path"
  command_line=$(ps -p "$pid" -o args=)
  [[ "$command_line" == *"$OUTPUT_DIR/usr/sbin/sshd"* ]] || die "refusing to accept unexpected OpenSSH PID $pid"
  info "OpenSSH server started on ${bind}:${port}"
}

run_client() {
  # Translate only explicitly configured client options; `default` leaves the
  # OpenSSH binary's built-in defaults unchanged.
  local -a options=()
  local key value option
  for key in kex_algorithms macs ciphers host_key_algorithms preferred_authentications password_authentication kbd_interactive_authentication strict_host_key_checking; do
    value=$(config_section_value client "$key")
    [[ -z "$value" || "$value" == default ]] && continue
    case "$key" in
      kex_algorithms) option=KexAlgorithms ;;
      macs) option=MACs ;;
      ciphers) option=Ciphers ;;
      host_key_algorithms) option=HostKeyAlgorithms ;;
      preferred_authentications) option=PreferredAuthentications ;;
      password_authentication) option=PasswordAuthentication ;;
      kbd_interactive_authentication) option=KbdInteractiveAuthentication ;;
      strict_host_key_checking) option=StrictHostKeyChecking ;;
    esac
    options+=(-o "$option=$value")
  done
  local library_path
  [[ -x "$OUTPUT_DIR/usr/bin/ssh" ]] || die 'OpenSSH is not built; run ./crypton build openssh'
  library_path=$(runtime_library_path)
  LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$OUTPUT_DIR/usr/bin/ssh" "${options[@]}" "$@"
}

stop_server() {
  # Verify the PID command line before sending a signal to avoid affecting a
  # system OpenSSH service or another user's process.
  local pid_path="$OUTPUT_DIR/run/crypton/openssh/sshd.pid" pid command_line attempt
  [[ -f "$pid_path" ]] || die "OpenSSH is not running (PID file not found: $pid_path)"
  pid=$(head -n 1 "$pid_path"); [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid OpenSSH PID file: $pid_path"
  if ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$pid_path"; info 'removed stale OpenSSH PID file'; return; fi
  command_line=$(ps -p "$pid" -o args=)
  [[ "$command_line" == *"$OUTPUT_DIR/usr/sbin/sshd"* ]] || die "refusing to stop unexpected process $pid"
  kill -TERM "$pid"
  for (( attempt = 0; attempt < 100; attempt++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$pid_path"; info 'OpenSSH stopped'; return; fi
    sleep 0.1
  done
  warn 'OpenSSH did not stop gracefully; sending SIGKILL'
  kill -KILL "$pid"; rm -f -- "$pid_path"
}

run() {
  # No mode means server for compatibility with `crypton run openssh`.
  [[ -x "$OUTPUT_DIR/usr/bin/ssh" && -x "$OUTPUT_DIR/usr/sbin/sshd" ]] || die 'OpenSSH is not built; run ./crypton build openssh'
  if (( $# == 0 )); then run_server; return; fi
  case "$1" in
    server) shift; run_server "$@" ;;
    client) shift; (( $# == 0 )) && { run_client -V; return; }; run_client "$@" ;;
    *) run_client "$@" ;;
  esac
}

require_project_config
command=${1:-build}; shift || true
case "$command" in
  build|compile) build "$@" ;;
  run) run "$@" ;;
  stop) stop_server ;;
  clean) clean_project ;;
  clean-sources) [[ "${1:-}" == --force ]] && clean_sources 1 || clean_sources ;;
  *) die "unknown command '$command' (use build, run, stop, clean, or clean-sources)" ;;
esac
