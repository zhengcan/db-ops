#!/bin/sh
# db-ops.sh - single-file MySQL backup/restore tool for bare Alpine.
set -eu

# ===================== Config defaults =====================
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_DATABASE="${DB_DATABASE:-}"
DB_ALL_DATABASES=0
FORCE=0
BACKUP_DIR=""
CONFIG_FILE=""

_TMP_DEFAULTS_FILE=""

# ===================== Generic helpers =====================
die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_common_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --host) DB_HOST="$2"; shift 2 ;;
      --port) DB_PORT="$2"; shift 2 ;;
      --user) DB_USER="$2"; shift 2 ;;
      --password) DB_PASSWORD="$2"; shift 2 ;;
      --database) DB_DATABASE="$2"; shift 2 ;;
      --all-databases) DB_ALL_DATABASES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dir) BACKUP_DIR="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# Scans "$@" for a `--config <file>` option only (does not parse any
# other options) and stores the result in $_EXTRACTED_CONFIG_FILE. Used
# by main() to discover CONFIG_FILE before load_config runs, so that
# config-file defaults can be established prior to the full CLI parse
# (which must take precedence over the config file).
extract_config_file() {
  _EXTRACTED_CONFIG_FILE=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) _EXTRACTED_CONFIG_FILE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

load_config() {
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

split_csv() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

confirm() {
  msg="$1"
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  printf '%s [y/N] ' "$msg"
  read -r reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ===================== Dependency management =====================
cleanup_common() {
  if [ -n "$_TMP_DEFAULTS_FILE" ] && [ -f "$_TMP_DEFAULTS_FILE" ]; then
    rm -f "$_TMP_DEFAULTS_FILE"
  fi
}
trap cleanup_common EXIT INT TERM

ensure_dependencies() {
  need_install=0
  for bin in mysql mysqldump mysqladmin gzip gawk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      need_install=1
    fi
  done

  if [ "$need_install" -eq 1 ]; then
    command -v apk >/dev/null 2>&1 || die "apk not found; cannot auto-install dependencies"
    apk add --no-cache mariadb-client mariadb-connector-c gzip gawk >&2 \
      || die "Failed to install dependencies via apk"
  fi

  for bin in mysql mysqldump mysqladmin gzip gawk; do
    command -v "$bin" >/dev/null 2>&1 || die "Required command still missing after install: $bin"
  done
}

# ===================== Connection helpers =====================

# Writes a temporary my.cnf-style defaults file containing the password,
# so it never appears in the process argument list. Sets _TMP_DEFAULTS_FILE.
make_defaults_file() {
  _TMP_DEFAULTS_FILE="$(mktemp)"
  chmod 600 "$_TMP_DEFAULTS_FILE"
  printf '[client]\npassword=%s\n' "$DB_PASSWORD" > "$_TMP_DEFAULTS_FILE"
}

# Each db_* wrapper below prepends the common connection flags to its
# positional parameters via `set --` (rather than an unquoted command
# substitution) so that values such as DB_HOST containing spaces are
# forwarded as single arguments, not word-split.

db_mysql() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  set -- \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl-mode=REQUIRED" \
    "--ssl-verify-server-cert=0" \
    "$@"
  mysql "$@"
}

db_mysqldump() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  set -- \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl-mode=REQUIRED" \
    "--ssl-verify-server-cert=0" \
    "$@"
  mysqldump "$@"
}

db_mysqladmin() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  set -- \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl-mode=REQUIRED" \
    "--ssl-verify-server-cert=0" \
    "$@"
  mysqladmin "$@"
}

check_connection() {
  db_mysqladmin ping >/dev/null 2>&1 || die "Cannot connect to MySQL at ${DB_HOST}:${DB_PORT}"
}

list_all_databases() {
  db_mysql -N -B -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys');"
}

# ===================== usage & main (placeholder, extended in later tasks) =====================
usage() {
  cat <<'EOF'
Usage: db-ops.sh <command> [options]

Commands:
  info      Show connection status and object overview
  backup    Backup one or more databases
  restore   Restore one or more databases from a backup directory

Common options:
  --config <file>       KEY=VALUE config file
  --host <host>         MySQL host (default 127.0.0.1)
  --port <port>         MySQL port (default 3306)
  --user <user>         MySQL user (default root)
  --password <password> MySQL password (prefer DB_PASSWORD env var)

backup options:
  --database <db1,db2>  Comma-separated list of databases to back up
  --all-databases        Back up all non-system databases

restore options:
  --dir <backup_dir>     Backup directory produced by 'backup'
  --database <db1,db2>   Comma-separated list of databases to restore
  --force                Skip confirmation prompt
EOF
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 1
  fi

  cmd="$1"
  shift

  extract_config_file "$@"
  CONFIG_FILE="$_EXTRACTED_CONFIG_FILE"
  load_config
  parse_common_args "$@"

  case "$cmd" in
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

if [ "${DB_OPS_TEST:-0}" != "1" ]; then
  main "$@"
fi
