#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

# Use the same project-local prefix selected by compile.sh. Keeping this
# lookup here lets `run` work when the prefix is changed from its default.
project_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$WORKSPACE_ROOT" "${1#./}" ;;
  esac
}

prefix_path=$(config_value prefix_path)
[[ -z "$prefix_path" ]] || OUTPUT_DIR=$(project_path "$prefix_path")

# Find a strongSwan executable without requiring a system installation.
find_binary() {
  local name=$1 path
  for path in "$OUTPUT_DIR/sbin/$name" "$OUTPUT_DIR/bin/$name" "$OUTPUT_DIR/libexec/ipsec/$name"; do
    [[ -x "$path" ]] || continue
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

# Run swanctl against this project's private VICI socket and libraries.
run_swanctl() {
  local swanctl library_path uri="unix://$OUTPUT_DIR/var/run/charon.vici"
  local arg has_uri=0
  swanctl=$(find_binary swanctl) || die 'swanctl is not built; run ./crypton build strongswan'
  library_path="$OUTPUT_ROOT/openssl/lib:$OUTPUT_DIR/lib:$OUTPUT_DIR/lib/ipsec"

  for arg in "$@"; do
    case "$arg" in
      --uri|-u|--uri=*) has_uri=1; break ;;
    esac
  done
  if (( has_uri == 0 )); then
    LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$swanctl" --uri "$uri" "$@"
  else
    LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$swanctl" "$@"
  fi
}

# Start charon with the project's configuration, PID file, VICI socket, and
# log. Charon still needs Linux network capabilities; the launcher cannot
# grant those privileges through environment variables.
run_daemon() {
  local charon runtime pid_file vici_socket log_file config
  local pid command_line attempt launcher_pid library_path
  charon=$(find_binary charon) || die 'charon is not built; run ./crypton build strongswan'
  runtime="$OUTPUT_DIR/var/run"
  pid_file="$runtime/charon.pid"
  vici_socket="$runtime/charon.vici"
  log_file="$OUTPUT_DIR/var/log/charon.log"
  config="$OUTPUT_DIR/etc/strongswan.conf"
  [[ -f "$config" ]] || die "strongSwan configuration not found: $config"
  mkdir -p "$runtime" "$OUTPUT_DIR/var/log"
  library_path="$OUTPUT_ROOT/openssl/lib:$OUTPUT_DIR/lib:$OUTPUT_DIR/lib/ipsec"

  # Stop a previous instance and remove a socket left by failed startup.
  [[ -f "$pid_file" ]] && stop_daemon
  rm -f -- "$vici_socket"

  STRONGSWAN_CONF="$config" \
  LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$charon" "$@" >"$log_file" 2>&1 &
  launcher_pid=$!

  # A successful command means charon created its private PID file.
  for attempt in {1..50}; do
    [[ -s "$pid_file" ]] && break
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      wait "$launcher_pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
  done
  if [[ ! -s "$pid_file" ]]; then
    rm -f -- "$vici_socket"
    if grep -Eq 'CAP_NET_ADMIN|CAP_NET_BIND_SERVICE|Operation not permitted|unmet dependency: CUSTOM:kernel-ipsec' "$log_file"; then
      die "charon needs Linux network capabilities (including CAP_NET_ADMIN); run with sudo or grant capabilities to $charon; inspect $log_file"
    fi
    die "charon did not start; inspect $log_file"
  fi

  pid=$(tr -d '[:space:]' < "$pid_file")
  [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid charon PID file: $pid_file"
  kill -0 "$pid" 2>/dev/null || die "charon exited; inspect $log_file"
  command_line=$(ps -p "$pid" -o args= 2>/dev/null || true)
  [[ "$command_line" == *"$charon"* ]] || die "PID file does not belong to this strongSwan bundle"
  [[ -S "$vici_socket" ]] || warn 'charon is running, but the private VICI socket is not ready yet'
  info "strongSwan charon started (pid $pid)"
  info "configuration: $config"
  info "log: $log_file"
}

# Stop only a charon process belonging to this project prefix.
stop_daemon() {
  local pid_file="$OUTPUT_DIR/var/run/charon.pid" pid command_line attempt
  [[ -f "$pid_file" ]] || { info 'strongSwan charon is not running'; return 0; }
  pid=$(tr -d '[:space:]' < "$pid_file")
  [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid charon PID file: $pid_file"
  if ! kill -0 "$pid" 2>/dev/null; then
    # A crashed daemon can leave its PID file and socket behind. They are
    # generated state, so remove them and allow the next start to proceed.
    rm -f -- "$pid_file" "$OUTPUT_DIR/var/run/charon.vici"
    info 'removed stale strongSwan runtime files'
    return 0
  fi
  command_line=$(ps -p "$pid" -o args= 2>/dev/null || true)
  [[ "$command_line" == *"$OUTPUT_DIR/"*charon* ]] || die "refusing to stop unrelated process from $pid_file"

  kill -TERM "$pid" 2>/dev/null || true
  for attempt in {1..50}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn 'charon did not stop gracefully; sending SIGKILL'
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f -- "$pid_file" "$OUTPUT_DIR/var/run/charon.vici"
  info 'strongSwan charon stopped'
}

require_project_config
command=${1:-run}; shift || true
case "$command" in
  run)
    if (( $# == 0 )); then run_daemon; else
      case "$1" in
        daemon|server) shift; run_daemon "$@" ;;
        swanctl|client) shift; run_swanctl "$@" ;;
        *) run_swanctl "$@" ;;
      esac
    fi
    ;;
  stop) stop_daemon ;;
  *) die "unknown runtime command '$command' (use run or stop)" ;;
esac
