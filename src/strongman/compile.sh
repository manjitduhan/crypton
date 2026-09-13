#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck source=../../scripts/project-common.sh
source "$PROJECT_DIR/../../scripts/project-common.sh"

resolve_project_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$WORKSPACE_ROOT" "${1#./}" ;;
  esac
}

# Create or update the Django administrator from project configuration. The
# password is passed through the child process environment, not its command
# line, so it does not appear in the process list.
configure_admin_user() {
  local username password
  username=$(config_section_value admin username)
  password=$(config_section_value admin password)
  [[ -n "$username" ]] || die 'admin.username is required in configure.yaml'
  [[ -n "$password" ]] || die 'admin.password is required in configure.yaml'
  [[ "$username" != *$'\n'* && "$username" != *$'\r'* ]] || die 'admin.username cannot contain a newline'
  [[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || die 'admin.password cannot contain a newline'

  (
    cd "$1"
    CRYPTON_STRONGMAN_ADMIN_USERNAME="$username" \
    CRYPTON_STRONGMAN_ADMIN_PASSWORD="$password" \
      "$2/bin/python" manage.py shell --settings=strongMan.settings.local -c '
import os
from django.contrib.auth import get_user_model

User = get_user_model()
username = os.environ["CRYPTON_STRONGMAN_ADMIN_USERNAME"]
password = os.environ["CRYPTON_STRONGMAN_ADMIN_PASSWORD"]
user = User.objects.filter(username=username).first()
if user is None:
    user = User.objects.order_by("pk").first() or User()
user.username = username
user.set_password(password)
user.is_active = True
user.is_staff = True
user.is_superuser = True
user.save()
'
  )
}

# StrongMan is an application rather than a conventional installable Python
# package, so its source and virtual environment are copied into output/.
build() {
  local venv="$OUTPUT_DIR/venv" app="$OUTPUT_DIR/app"
  checkout_project
  mkdir -p "$OUTPUT_DIR"
  python3 -m venv "$venv"
  # Keep runtime state out of the source checkout while making the output copy
  # reproducible whenever the upstream revision or local patches change.
  rm -rf -- "$app"
  cp -a "$SOURCE_DIR" "$app"
  apply_project_patches "$app"
  [[ -f "$app/requirements.txt" ]] || die 'strongMan requirements.txt not found'
  "$venv/bin/python" -m pip install -r "$app/requirements.txt" "$@"
  # Initialize the isolated application database and static assets after the
  # dependencies are installed.
  (cd "$app" && "$venv/bin/python" manage.py migrate --settings=strongMan.settings.local)
  (cd "$app" && "$venv/bin/python" manage.py loaddata initial_data.json --settings=strongMan.settings.local)
  configure_admin_user "$app" "$venv"
  (cd "$app" && "$venv/bin/python" manage.py collectstatic --settings=strongMan.settings.production --noinput)
  info "built into $OUTPUT_DIR"
}

run() {
  # Runtime values are project-local configuration. Environment variables are
  # explicit one-run overrides, useful for service managers and diagnostics.
  local workers bind allowed_hosts vici_socket
  workers=$(config_section_value server workers)
  bind=$(config_section_value server bind)
  allowed_hosts=$(config_section_value server allowed_hosts)
  vici_socket=$(config_value vici_socket)
  workers=${CRYPTON_STRONGMAN_WORKERS:-${workers:-1}}
  bind=${CRYPTON_STRONGMAN_BIND:-${bind:-0.0.0.0:1515}}
  allowed_hosts=${CRYPTON_STRONGMAN_ALLOWED_HOSTS:-${allowed_hosts:-*}}
  vici_socket=${CRYPTON_STRONGMAN_VICI_SOCKET:-${vici_socket:-$OUTPUT_ROOT/strongswan/var/run/charon.vici}}
  [[ "$vici_socket" == /* ]] || vici_socket=$(resolve_project_path "$vici_socket")
  [[ "$workers" =~ ^[1-9][0-9]*$ ]] || die "invalid StrongMan worker count: $workers"
  [[ -n "$bind" && "$bind" != *[[:space:]]* ]] || die "invalid StrongMan bind address: $bind"
  [[ "$allowed_hosts" != *$'\n'* && "$allowed_hosts" != *$'\r'* ]] || die 'invalid StrongMan allowed_hosts value'
  [[ -n "$vici_socket" && "$vici_socket" != *$'\n'* && "$vici_socket" != *$'\r'* ]] || die 'invalid StrongMan VICI socket path'
  [[ -x "$OUTPUT_DIR/venv/bin/python" && -d "$OUTPUT_DIR/app/strongMan" ]] || die 'strongMan is not built; run ./crypton build strongman'
  (
    # Django reads this variable from the patched settings module. Export it
    # only for this process so it cannot leak into unrelated project commands.
    export CRYPTON_STRONGMAN_ALLOWED_HOSTS="$allowed_hosts"
    export CRYPTON_STRONGMAN_VICI_SOCKET="$vici_socket"
    cd "$OUTPUT_DIR/app"
    exec "$OUTPUT_DIR/venv/bin/python" -m gunicorn \
      --workers="$workers" \
      --bind="$bind" \
      --pid="$OUTPUT_DIR/strongman.pid" \
      --env DJANGO_SETTINGS_MODULE=strongMan.settings.local \
      strongMan.wsgi:application "$@"
  )
}

stop() {
  # Use the PID file only after verifying that it belongs to our Gunicorn
  # command; this prevents stopping an unrelated process by mistake.
  local pid_path="$OUTPUT_DIR/strongman.pid" pid command_line attempt
  [[ -f "$pid_path" ]] || die "strongMan is not running (PID file not found: $pid_path)"
  pid=$(head -n 1 "$pid_path")
  [[ "$pid" =~ ^[0-9]+$ ]] || die "invalid strongMan PID file: $pid_path"
  if ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$pid_path"; info 'removed stale strongMan PID file'; return; fi
  command_line=$(ps -p "$pid" -o args=)
  [[ "$command_line" == *"$OUTPUT_DIR/venv/bin/python -m gunicorn"*"strongMan.wsgi:application"* ]] || die "refusing to stop unexpected process $pid"
  kill -TERM "$pid"
  for (( attempt = 0; attempt < 100; attempt++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then rm -f -- "$pid_path"; info 'strongMan stopped'; return; fi
    sleep 0.1
  done
  warn 'strongMan did not stop gracefully; sending SIGKILL'
  kill -KILL "$pid"
  rm -f -- "$pid_path"
}

require_project_config
command=${1:-build}; shift || true
case "$command" in
  build|compile) build "$@" ;;
  run) run "$@" ;;
  stop) stop ;;
  clean) clean_project ;;
  clean-sources) [[ "${1:-}" == --force ]] && clean_sources 1 || clean_sources ;;
  *) die "unknown command '$command' (use build, run, stop, clean, or clean-sources)" ;;
esac
