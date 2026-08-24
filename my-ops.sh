#!/bin/sh
# my-ops.sh - single-file MySQL backup/restore tool for bare Alpine.
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
INSTANCE_NAME=""
CONFIG_INSTANCE_TYPE=""
DEFAULT_CONFIG_FILE="dbs.conf"

_TMP_DEFAULTS_FILE=""
_TMP_FILES_TO_CLEAN=""

# ===================== Generic helpers =====================
die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Single source of truth for "which global options consume the following
# argument as their value". Used both by the argument parsers below and by
# main()'s command-word scan (which must skip these values so it never
# mistakes one for the command name, e.g. `--host backup info`). If you add
# a new value-taking global option, update this function AND the matching
# `case` arm in parse_common_args()/extract_config_file() together.
_is_value_flag() {
  case "$1" in
    --config|--instance|--host|--port|--user|--password|--database|--dir) return 0 ;;
    *) return 1 ;;
  esac
}

parse_common_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) [ "$#" -ge 2 ] || die "--config requires a value"; CONFIG_FILE="$2"; shift 2 ;;
      --instance) [ "$#" -ge 2 ] || die "--instance requires a value"; INSTANCE_NAME="$2"; shift 2 ;;
      --host) [ "$#" -ge 2 ] || die "--host requires a value"; DB_HOST="$2"; shift 2 ;;
      --port) [ "$#" -ge 2 ] || die "--port requires a value"; DB_PORT="$2"; shift 2 ;;
      --user) [ "$#" -ge 2 ] || die "--user requires a value"; DB_USER="$2"; shift 2 ;;
      --password) [ "$#" -ge 2 ] || die "--password requires a value"; DB_PASSWORD="$2"; shift 2 ;;
      --database) [ "$#" -ge 2 ] || die "--database requires a value"; DB_DATABASE="$2"; shift 2 ;;
      --all-databases) DB_ALL_DATABASES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dir) [ "$#" -ge 2 ] || die "--dir requires a value"; BACKUP_DIR="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# Scans "$@" for `--config <file>` and `--instance <name>` options only
# (does not parse any other options) and stores the results in
# $_EXTRACTED_CONFIG_FILE / $_EXTRACTED_INSTANCE. Used by main() to discover
# CONFIG_FILE/INSTANCE_NAME before resolve_config_instance runs, so that
# config-file defaults can be established prior to the full CLI parse
# (which must take precedence over the config file).
extract_config_file() {
  _EXTRACTED_CONFIG_FILE=""
  _EXTRACTED_INSTANCE=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) [ "$#" -ge 2 ] || die "--config requires a value"; _EXTRACTED_CONFIG_FILE="$2"; shift 2 ;;
      --instance) [ "$#" -ge 2 ] || die "--instance requires a value"; _EXTRACTED_INSTANCE="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# Parses an INI-style config file and prints one instance name per line
# (the text inside each `[name]` section header), in the order they appear.
# Lines that don't look like `[name]` (including comments and blank lines)
# are ignored.
list_config_instances() {
  file="$1"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[*\])
        name="${line#\[}"
        name="${name%\]}"
        printf '%s\n' "$name"
        ;;
      *) ;;
    esac
  done < "$file"
}

# Parses an INI-style config file and loads the `type`/`host`/`port`/`user`/
# `password`/`database` fields of the `[instance_name]` section into
# CONFIG_INSTANCE_TYPE / DB_HOST / DB_PORT / DB_USER / DB_PASSWORD /
# DB_DATABASE respectively. Only fields present with a non-empty value in
# the section overwrite the corresponding global; other globals are left
# untouched (so CLI/env defaults established earlier still stand for any
# field the instance doesn't define). Unknown keys are ignored. Lines
# starting with `#` or `;` and blank lines are ignored. Both `key = value`
# and `key=value` are accepted.
load_config_instance() {
  file="$1"
  target="$2"
  in_section=0
  CONFIG_INSTANCE_TYPE=""
  cfg_host="" cfg_port="" cfg_user="" cfg_password="" cfg_database=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      \[*\])
        name="${line#\[}"
        name="${name%\]}"
        if [ "$name" = "$target" ]; then
          in_section=1
        else
          in_section=0
        fi
        continue
        ;;
      *) ;;
    esac
    [ "$in_section" -eq 1 ] || continue
    case "$line" in
      ''|'#'*|';'*) continue ;;
      *) ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    key_lc="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    case "$key_lc" in
      type) CONFIG_INSTANCE_TYPE="$value" ;;
      host) cfg_host="$value" ;;
      port) cfg_port="$value" ;;
      user) cfg_user="$value" ;;
      password) cfg_password="$value" ;;
      database) cfg_database="$value" ;;
      *) ;;
    esac
  done < "$file"
  [ -n "$cfg_host" ] && DB_HOST="$cfg_host"
  [ -n "$cfg_port" ] && DB_PORT="$cfg_port"
  [ -n "$cfg_user" ] && DB_USER="$cfg_user"
  [ -n "$cfg_password" ] && DB_PASSWORD="$cfg_password"
  [ -n "$cfg_database" ] && DB_DATABASE="$cfg_database"
  return 0
}

# Orchestrates the full "determine config file -> enumerate instances ->
# select instance -> validate type -> load fields" flow:
#   1. If $CONFIG_FILE is set (from --config), it must exist or this dies.
#      Otherwise, if ./dbs.conf exists in the current directory, it is used
#      automatically. Otherwise, config-file handling is skipped entirely
#      and this function is a no-op (pure CLI/env-var usage, unchanged).
#   2. Enumerates all `[instance]` sections. Zero instances is an error.
#      With exactly one instance, it is auto-selected (an explicit
#      --instance naming anything else is an error). With two or more,
#      --instance is required and must name one of them.
#   3. Loads the selected instance's fields. Its `type` (case-insensitive)
#      must be `mysql`, or this dies.
# CLI arguments are parsed afterward by parse_common_args and always take
# precedence over whatever this function loads.
resolve_config_instance() {
  config_file_to_use=""
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    config_file_to_use="$CONFIG_FILE"
  elif [ -f "$DEFAULT_CONFIG_FILE" ]; then
    config_file_to_use="$DEFAULT_CONFIG_FILE"
  fi

  [ -n "$config_file_to_use" ] || return 0

  instances="$(list_config_instances "$config_file_to_use" | grep . || true)"
  instance_count=0
  if [ -n "$instances" ]; then
    instance_count="$(printf '%s\n' "$instances" | grep -c .)"
  fi

  [ "$instance_count" -gt 0 ] \
    || die "Config file '$config_file_to_use' exists but defines no instances (no [name] sections found)"

  available="$(printf '%s\n' "$instances" | tr '\n' ' ' | sed 's/ *$//')"

  if [ "$instance_count" -eq 1 ]; then
    only_instance="$instances"
    if [ -n "$INSTANCE_NAME" ] && [ "$INSTANCE_NAME" != "$only_instance" ]; then
      die "Instance '$INSTANCE_NAME' not found in config file '$config_file_to_use'. Available instances: $available"
    fi
    selected="$only_instance"
  else
    [ -n "$INSTANCE_NAME" ] \
      || die "Config file '$config_file_to_use' defines multiple instances; specify --instance <name>. Available instances: $available"
    if ! printf '%s\n' "$instances" | grep -qx -- "$INSTANCE_NAME"; then
      die "Instance '$INSTANCE_NAME' not found in config file '$config_file_to_use'. Available instances: $available"
    fi
    selected="$INSTANCE_NAME"
  fi

  load_config_instance "$config_file_to_use" "$selected"

  type_lc="$(printf '%s' "$CONFIG_INSTANCE_TYPE" | tr '[:upper:]' '[:lower:]')"
  [ "$type_lc" = "mysql" ] \
    || die "Instance '$selected' has type=${CONFIG_INSTANCE_TYPE}, but my-ops.sh only supports mysql instances"

  # Record the actually-resolved instance name (covers both the
  # auto-selected single-instance case and an explicit --instance), so
  # callers like cmd_backup's default path naming can use it.
  INSTANCE_NAME="$selected"
}


# Validates identifiers (database/table/column names) with an allowlist:
# only letters, digits, and underscores are permitted. This is deliberately
# strict rather than trying to blacklist specific dangerous characters
# (backtick, single quote, semicolon, whitespace, comment markers, etc.)
# because these identifiers get interpolated into SQL in multiple contexts
# across this script: some inside backtick-quoted identifiers (where a
# backtick could break out) and some inside single-quoted string literals
# (e.g. WHERE TABLE_SCHEMA='${db}', where a single quote, semicolon, or
# comment sequence could break out). An allowlist of safe characters closes
# off both injection classes at once instead of chasing each context's
# specific escape character. Legitimate database/table/column names in
# normal operational use consist of letters, digits, and underscores, so
# this is safe for real-world use.
validate_identifier() {
  case "$1" in
    *[!A-Za-z0-9_]*|'') die "Invalid identifier (only letters, digits, and underscores are allowed): $1" ;;
  esac
}

# Sanitizes an arbitrary string for safe use as a single path component
# (e.g. a hostname embedded in a backup directory path). Unlike
# validate_identifier (which rejects anything outside its allowlist),
# this function is permissive: any character outside the allowlist of
# letters, digits, '.', '-', and '_' is replaced with '_' rather than
# causing the script to abort. This is deliberately more lenient because
# the value can come from --host / $DB_HOST, which may legitimately
# contain dots (FQDNs) or dashes, but must never be allowed to inject
# path separators ('/') or otherwise escape the intended directory
# structure (e.g. via '..'). The sanitized result is written to stdout.
sanitize_path_component() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

split_csv() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | { grep -v '^$' || true; }
}

confirm() {
  msg="$1"
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  printf '%s [y/N] ' "$msg"
  # Read the answer from the controlling terminal rather than the script's
  # inherited stdin. This is critical when confirm() is called from inside a
  # loop that is itself reading a list of items from stdin via a pipe (e.g.
  # `cmd_restore`'s `printf '%s\n' "$databases" | while read -r db; do ...`):
  # if confirm() read from the same stdin, its `read -r reply` would consume
  # the *next* database name off the pipe instead of the user's actual
  # keystroke, silently corrupting the loop. `/dev/tty` is not affected by
  # that pipe, so it is unambiguously "what the interactive user typed".
  #
  # DB_OPS_TEST_CONFIRM_STDIN=1 lets unit tests simulate answers by piping
  # into stdin (there is no real tty available in a test/CI sandbox); it
  # must never be set in production use. (Note: this is intentionally a
  # separate variable from DB_OPS_TEST, which suppresses running `main` --
  # tests that need the real CLI to execute still need main() to run.)
  if [ "${DB_OPS_TEST_CONFIRM_STDIN:-0}" = "1" ]; then
    read -r reply
  else
    read -r reply < /dev/tty
  fi
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ===================== Dependency management =====================

# Registers a temporary file path so that cleanup_common() removes it on
# exit even if the caller dies (via `die`/`set -e`) before reaching its own
# normal `rm -f` cleanup line. Also chmods the file to 600 immediately,
# since every temp file registered here carries plaintext database
# credentials or dump data. Call this immediately after every `mktemp`
# invocation that produces a file needing cleanup.
register_tmp_file() {
  _TMP_FILES_TO_CLEAN="$_TMP_FILES_TO_CLEAN $1"
  chmod 600 "$1"
}

cleanup_common() {
  if [ -n "$_TMP_DEFAULTS_FILE" ] && [ -f "$_TMP_DEFAULTS_FILE" ]; then
    rm -f "$_TMP_DEFAULTS_FILE"
  fi
  # shellcheck disable=SC2086
  if [ -n "$_TMP_FILES_TO_CLEAN" ]; then
    rm -f $_TMP_FILES_TO_CLEAN 2>/dev/null || true
  fi
}
trap cleanup_common EXIT INT TERM

MYSQL_BIN="mysql"
MYSQLDUMP_BIN="mysqldump"
MYSQLADMIN_BIN="mysqladmin"

# Prefer the non-deprecated mariadb/mariadb-dump/mariadb-admin binaries when
# available, falling back to the mysql/mysqldump/mysqladmin compatibility
# shims otherwise. Using the mariadb-* names directly avoids the
# "Deprecated program name" warning those shims print on stderr.
detect_mysql_binaries() {
  command -v mariadb >/dev/null 2>&1 && MYSQL_BIN="mariadb"
  command -v mariadb-dump >/dev/null 2>&1 && MYSQLDUMP_BIN="mariadb-dump"
  command -v mariadb-admin >/dev/null 2>&1 && MYSQLADMIN_BIN="mariadb-admin"
  return 0
}

# Returns success if either name of a mysql-family tool is available
# (e.g. "mysql" or "mariadb"), since a mariadb-client install may only
# provide the newer mariadb-* names.
_have_either() {
  command -v "$1" >/dev/null 2>&1 || command -v "$2" >/dev/null 2>&1
}

ensure_dependencies() {
  need_install=0
  _have_either mysql mariadb || need_install=1
  _have_either mysqldump mariadb-dump || need_install=1
  _have_either mysqladmin mariadb-admin || need_install=1
  for bin in gzip gawk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      need_install=1
    fi
  done

  if [ "$need_install" -eq 1 ]; then
    command -v apk >/dev/null 2>&1 || die "apk not found; cannot auto-install dependencies"
    apk add --no-cache mariadb-client mariadb-connector-c gzip gawk >&2 \
      || die "Failed to install dependencies via apk"
  fi

  _have_either mysql mariadb || die "Required command still missing after install: mysql/mariadb"
  _have_either mysqldump mariadb-dump || die "Required command still missing after install: mysqldump/mariadb-dump"
  _have_either mysqladmin mariadb-admin || die "Required command still missing after install: mysqladmin/mariadb-admin"
  for bin in gzip gawk; do
    command -v "$bin" >/dev/null 2>&1 || die "Required command still missing after install: $bin"
  done

  detect_mysql_binaries
}

# ===================== Connection helpers =====================

# Writes a temporary my.cnf-style defaults file containing the password,
# so it never appears in the process argument list. Sets _TMP_DEFAULTS_FILE.
#
# The password value is wrapped in double quotes with internal backslashes
# and double quotes escaped. This is required because MySQL/MariaDB option
# file syntax treats an unquoted `#` as the start of a line comment: an
# unquoted password containing `#` would be silently truncated at that
# character, producing an authentication failure with no indication of the
# real cause. Quoting the value disables comment-parsing within it.
make_defaults_file() {
  _TMP_DEFAULTS_FILE="$(mktemp)"
  register_tmp_file "$_TMP_DEFAULTS_FILE"
  esc_pw=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '[client]\npassword="%s"\n' "$esc_pw" > "$_TMP_DEFAULTS_FILE"
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
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
    "--default-character-set=utf8mb4" \
    "$@"
  "$MYSQL_BIN" "$@"
}

# NOTE on --default-character-set=utf8mb4 (both here and in db_mysqldump below):
# restore_one_database() splits a single mysqldump output into a schema part
# and a data part (see the `awk '/^INSERT INTO /{in_insert=1}...'` split
# below), then imports each part via *separate* db_mysql invocations (i.e.
# separate connections). mysqldump's own "/*!40101 SET NAMES utf8mb4 */;"
# header line always lands in the schema part (it appears before the first
# INSERT line), so the data-import connection never sees it and falls back
# to the mysql/mariadb client library's own compiled-in default charset --
# which is NOT always utf8mb4 (e.g. Alpine's mariadb-connector-c defaults to
# utf8mb3, a 3-byte encoding). Any 4-byte UTF-8 data (emoji, some CJK
# extension characters, etc.) would then be rejected with
# "ERROR 1366: Incorrect string value" even though the target column is a
# correctly-defined utf8mb4 column that can hold it just fine. Passing
# --default-character-set=utf8mb4 explicitly on every connection removes the
# dependency on that embedded SET NAMES line surviving the split, and is
# applied unconditionally (not just for the data-import path) so all
# connections behave consistently.
db_mysqldump() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  set -- \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
    "--default-character-set=utf8mb4" \
    "$@"
  "$MYSQLDUMP_BIN" "$@"
}

db_mysqladmin() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  set -- \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
    "$@"
  "$MYSQLADMIN_BIN" "$@"
}

check_connection() {
  db_mysqladmin ping >/dev/null 2>&1 || die "Cannot connect to MySQL at ${DB_HOST}:${DB_PORT}"
}

list_all_databases() {
  db_mysql -N -B -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys','mysql_innodb_cluster_metadata');"
}

# Resolves which databases to operate on based on --all-databases / --database
# flags, and validates the resulting list is non-empty. Echoes the newline
# separated list of database names, one per line, to stdout.
resolve_target_databases() {
  target_databases=""
  if [ "$DB_ALL_DATABASES" -eq 1 ] && [ -n "$DB_DATABASE" ]; then
    die "Cannot combine --database and --all-databases"
  fi
  if [ "$DB_ALL_DATABASES" -eq 1 ]; then
    target_databases="$(list_all_databases)"
  elif [ -n "$DB_DATABASE" ]; then
    target_databases="$(split_csv "$DB_DATABASE")"
  else
    die "Specify --database <db1,db2> or --all-databases"
  fi

  [ -n "$(printf '%s' "$target_databases" | tr -d '[:space:]')" ] || die "No databases to process"

  # Validate every database name before returning. Deliberately done with a
  # `for` loop over word-split $target_databases (not `... | while read`)
  # so that a validate_identifier failure (which calls die -> exit) actually
  # terminates the whole script instead of only a pipeline subshell.
  _old_ifs="$IFS"
  IFS='
'
  for _db in $target_databases; do
    [ -n "$_db" ] || continue
    validate_identifier "$_db"
  done
  IFS="$_old_ifs"

  printf '%s\n' "$target_databases"
}

# ===================== info subcommand =====================
cmd_info() {
  ensure_dependencies
  check_connection
  echo "Connection OK: ${DB_USER}@${DB_HOST}:${DB_PORT}"

  databases="$(resolve_target_databases)"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    echo ""
    echo "Database: $db"
    tables=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';") \
      || die "Failed to query object counts for database: $db"
    views=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='VIEW';") \
      || die "Failed to query object counts for database: $db"
    routines=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${db}';") \
      || die "Failed to query object counts for database: $db"
    triggers=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${db}';") \
      || die "Failed to query object counts for database: $db"
    events=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='${db}';") \
      || die "Failed to query object counts for database: $db"
    echo "  Tables:               $tables"
    echo "  Views:                $views"
    echo "  Routines (proc/func): $routines"
    echo "  Triggers:             $triggers"
    echo "  Events:               $events"
  done
}

# ===================== backup subcommand =====================
cmd_backup() {
  ensure_dependencies
  check_connection

  databases="$(resolve_target_databases)"

  timestamp="$(date +%Y%m%d_%H%M%S)"
  if [ -n "$BACKUP_DIR" ]; then
    [ -d "$BACKUP_DIR" ] || die "Backup base directory not found: $BACKUP_DIR"
    out_dir="${BACKUP_DIR%/}/backup_${timestamp}"
  else
    # Prefer the dbs.conf instance name (stable, human-chosen) when one was
    # resolved; otherwise fall back to the sanitized connection host, as
    # before (pure CLI/env-var usage with no config file in play).
    if [ -n "$INSTANCE_NAME" ]; then
      safe_label="$(sanitize_path_component "$INSTANCE_NAME")"
    else
      safe_label="$(sanitize_path_component "$DB_HOST")"
    fi
    out_dir="backup/mysql/${safe_label}/${timestamp}"
  fi
  mkdir -p "$out_dir"

  # Tracks which databases had routine dumping degraded (see
  # dump_schema_with_package_status_fallback). The backup loop below runs as
  # the receiving end of a pipe, i.e. in a subshell, so a plain variable set
  # inside it would not survive past `done`; a temp file is used instead so
  # the summary warning after the loop can see what happened inside it.
  degraded_routines_file="$(mktemp)"
  register_tmp_file "$degraded_routines_file"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    table_count=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';") \
      || die "Failed to query table count for database: $db"
    echo "Backing up database: $db (${table_count} table(s))..."
    backup_one_database "$db" "$out_dir/${db}.sql.gz" "$degraded_routines_file"
    echo "Completed database: $db"
  done

  echo "Backup complete: $out_dir"

  degraded_routines="$(tr '\n' ' ' < "$degraded_routines_file" | sed 's/ *$//')"
  if [ -n "$degraded_routines" ]; then
    degraded_count="$(printf '%s\n' "$degraded_routines" | tr ' ' '\n' | grep -c .)"
    echo "WARNING: ${degraded_count} database(s) had stored routines/functions omitted due to a mariadb-dump version-detection issue: ${degraded_routines}" >&2
  fi
}

# Runs the schema-only mysqldump pass (--no-data --routines --triggers
# --events) for $db into $tmp_sql. If it fails because mariadb-dump
# misdetected the server as MariaDB 10.3+ (recognizable by the `SHOW PACKAGE
# STATUS` probe it issues for --routines, which MySQL servers reject with a
# syntax error), discards the partial output, warns, and retries once
# without --routines. Any other failure is fatal. On a routines-fallback,
# appends $db to $degraded_routines_file so the caller can summarize it.
dump_schema_with_package_status_fallback() {
  db="$1"
  tmp_sql="$2"
  degraded_routines_file="$3"

  err_file="$(mktemp)"
  register_tmp_file "$err_file"

  if db_mysqldump --no-data --routines --triggers --events "$db" \
      >> "$tmp_sql" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi

  schema_err="$(cat "$err_file")"
  rm -f "$err_file"

  case "$schema_err" in
    # NOTE: fragile-by-design substring match against mariadb-dump's exact
    # error text. If a future mariadb-dump version changes this wording
    # (localization, "PACKAGE BODY STATUS" instead, etc.), this fallback
    # will silently stop triggering and the schema dump will just die()
    # with the original error -- if this fix "stops working" after an
    # apk/mariadb-client upgrade, check whether the error text changed.
    *"PACKAGE STATUS"*)
      # Discard whatever partial schema output the failed attempt may have
      # already appended to $tmp_sql before retrying. Do not print a
      # per-database warning here -- it fires once per affected database
      # and is pure noise in a multi-database backup; cmd_backup prints a
      # single summary line after the loop listing every degraded database.
      : > "$tmp_sql"
      echo "$db" >> "$degraded_routines_file"

      db_mysqldump --no-data --triggers --events "$db" >> "$tmp_sql" \
        || die "Schema dump failed for database: $db (retry without --routines also failed; original error: $schema_err)"
      ;;
    *)
      die "Schema dump failed for database: $db: $schema_err"
      ;;
  esac
}

backup_one_database() {
  db="$1"
  out_file="$2"
  degraded_routines_file="$3"
  tmp_sql="$(mktemp)"
  register_tmp_file "$tmp_sql"

  dump_schema_with_package_status_fallback "$db" "$tmp_sql" "$degraded_routines_file"

  db_mysqldump --no-create-info --complete-insert --skip-extended-insert \
    --hex-blob --single-transaction \
    --skip-triggers --skip-routines --skip-events "$db" >> "$tmp_sql" \
    || die "Data dump failed for database: $db"

  gzip -c "$tmp_sql" > "$out_file"
  rm -f "$tmp_sql"
}

# ===================== restore subcommand =====================

# Rewrites the INSERT column-name list (never the VALUES clause) so that
# generated columns (listed in `mapfile`, tab-separated "table<TAB>column")
# are redirected to <column>__tmp during data import. Invoked as:
#   gawk -v mapfile=<path> "$GENCOL_AWK_PROGRAM" data.sql
GENCOL_AWK_PROGRAM='
BEGIN {
  if (mapfile != "") {
    while ((getline mline < mapfile) > 0) {
      split(mline, parts, "\t")
      if (parts[1] != "" && parts[2] != "") {
        gencols[parts[1] SUBSEP parts[2]] = 1
      }
    }
    close(mapfile)
  }
}

{
  line = $0
  if (match(line, /^INSERT INTO `([^`]+)` \(/, m)) {
    table = m[1]
    open_paren = index(line, "(")
    values_pos = index(line, ") VALUES")
    if (open_paren > 0 && values_pos > open_paren) {
      col_list = substr(line, open_paren + 1, values_pos - open_paren - 1)
      n = split(col_list, cols, ", ")
      out = ""
      for (i = 1; i <= n; i++) {
        col = cols[i]
        colname = col
        gsub(/`/, "", colname)
        if ((table SUBSEP colname) in gencols) {
          col = "`" colname "__tmp`"
        }
        out = (i == 1) ? col : out ", " col
      }
      line = substr(line, 1, open_paren) out substr(line, values_pos)
    }
  }
  print line
}
'

cmd_restore() {
  ensure_dependencies
  check_connection

  [ "$DB_ALL_DATABASES" -eq 1 ] && [ -n "$DB_DATABASE" ] \
    && die "Cannot combine --database and --all-databases"
  [ "$DB_ALL_DATABASES" -eq 1 ] \
    && die "restore does not support --all-databases; specify an explicit --database list"

  [ -n "$BACKUP_DIR" ] || die "Specify --dir <backup_dir>"
  [ -d "$BACKUP_DIR" ] || die "Backup directory not found: $BACKUP_DIR"
  [ -n "$DB_DATABASE" ] || die "Specify --database <db1,db2> (explicit list required)"

  databases="$(split_csv "$DB_DATABASE")"

  _old_ifs="$IFS"
  IFS='
'
  for _db in $databases; do
    [ -n "$_db" ] || continue
    validate_identifier "$_db"
  done
  IFS="$_old_ifs"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    archive="$BACKUP_DIR/${db}.sql.gz"
    [ -f "$archive" ] || die "Backup file not found: $archive"

    confirm "This will DROP and recreate database '$db'. Continue?" \
      || die "Aborted by user for database: $db"

    restore_one_database "$db" "$archive"
    echo "Restored database: $db"
  done
}

restore_one_database() {
  db="$1"
  archive="$2"
  tmp_sql="$(mktemp)"
  register_tmp_file "$tmp_sql"
  gzip -dc "$archive" > "$tmp_sql" || die "Failed to decompress backup archive: $archive"

  db_mysql -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\`;" < /dev/null \
    || die "Failed to (re)create database: $db"

  tmp_sql_filtered="$(mktemp)"
  register_tmp_file "$tmp_sql_filtered"
  # This is a text-substring filter, not a real SQL parser: it strips any
  # line that textually matches the SET @OLD_.../SET ...=@OLD_... pattern.
  # If a row's data happens to contain a literal string matching this
  # pattern (e.g. a text column value like "SET @OLD_FOO=1"), that INSERT
  # line would be silently filtered out and its data lost. This is a known,
  # accepted limitation -- a true SQL parser would avoid it but is not
  # justified by the cost for this tool's scope. `|| true` guards against
  # grep's exit code 1 when every line is filtered out (e.g. a table with
  # no bookkeeping lines at all), matching the same convention already used
  # by split_csv().
  grep -Ev '(SET @OLD_[A-Za-z_]+=|SET [A-Za-z_]+=@OLD_[A-Za-z_]+)' "$tmp_sql" > "$tmp_sql_filtered" || true

  schema_sql="$(mktemp)"
  data_sql="$(mktemp)"
  register_tmp_file "$schema_sql"
  register_tmp_file "$data_sql"
  awk -v schema_out="$schema_sql" -v data_out="$data_sql" '
    /^INSERT INTO / { in_insert = 1 }
    in_insert { print >> data_out; next }
    { print >> schema_out }
  ' "$tmp_sql_filtered"

  { printf '%s\n' "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;"; cat "$schema_sql"; printf '%s\n' "COMMIT;"; } \
    | db_mysql "$db" || die "Failed to import schema for database: $db"

  map_raw="$(mktemp)"
  map_file="$(mktemp)"
  register_tmp_file "$map_raw"
  register_tmp_file "$map_file"
  db_mysql -N -B -e "
    SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='${db}'
      AND GENERATION_EXPRESSION IS NOT NULL
      AND GENERATION_EXPRESSION != '';
  " < /dev/null > "$map_raw"

  : > "$map_file"
  while IFS="$(printf '\t')" read -r tbl col coltype; do
    [ -n "$tbl" ] || continue
    validate_identifier "$tbl"
    validate_identifier "$col"
    printf '%s\t%s\n' "$tbl" "$col" >> "$map_file"
    db_mysql "$db" -e "ALTER TABLE \`${tbl}\` ADD COLUMN \`${col}__tmp\` ${coltype} NULL;" < /dev/null \
      || die "Failed to add temp column ${col}__tmp on ${tbl}"
  done < "$map_raw"

  if [ -s "$map_file" ]; then
    filtered_data_sql="$(mktemp)"
    register_tmp_file "$filtered_data_sql"
    gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql" > "$filtered_data_sql"
    { printf '%s\n' "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;"; cat "$filtered_data_sql"; printf '%s\n' "COMMIT;"; } \
      | db_mysql "$db" || die "Failed to import data for database: $db"
    rm -f "$filtered_data_sql"

    while IFS="$(printf '\t')" read -r tbl col; do
      [ -n "$tbl" ] || continue
      db_mysql "$db" -e "ALTER TABLE \`${tbl}\` DROP COLUMN \`${col}__tmp\`;" < /dev/null \
        || die "Failed to drop temp column ${col}__tmp on ${tbl}"
    done < "$map_file"
  else
    { printf '%s\n' "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;"; cat "$data_sql"; printf '%s\n' "COMMIT;"; } \
      | db_mysql "$db" || die "Failed to import data for database: $db"
  fi

  rm -f "$tmp_sql" "$tmp_sql_filtered" "$schema_sql" "$data_sql" "$map_file" "$map_raw"
}

# ===================== usage & main (placeholder, extended in later tasks) =====================
usage() {
  cat <<'EOF'
Usage: my-ops.sh <command> [options]
       my-ops.sh [options] <command> [options]

Global options may be placed before the command, after the command, or
mixed on both sides, in any order.

Commands:
  info      Show connection status and object overview
  backup    Backup one or more databases
  restore   Restore one or more databases from a backup directory

Common options:
  --config <file>        INI-style multi-instance config file (default:
                         ./dbs.conf if it exists in the current directory)
  --instance <name>      Instance section to use from the config file.
                         Required when the config file defines 2+
                         instances; optional (and must match) when it
                         defines exactly 1.
  --host <host>         MySQL host (default 127.0.0.1)
  --port <port>         MySQL port (default 3306)
  --user <user>         MySQL user (default root)
  --password <password> MySQL password (prefer DB_PASSWORD env var)

backup options:
  --database <db1,db2>  Comma-separated list of databases to back up
  --all-databases        Back up all non-system databases
  --dir <path>           Base directory to place the timestamped backup_<ts>/
                         folder in (default: backup/mysql/<host>/<timestamp>/
                         under the current directory, where <host> is the
                         sanitized --host value)

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

  # Scan all args (read-only, no shifting) to find the command word,
  # wherever it appears. This allows global options to be placed before
  # the command, after it, or mixed on both sides. Values belonging to
  # options that take one (e.g. --host foo) are skipped so they can
  # never be mistaken for the command, even if they happen to look like
  # one (e.g. --host backup).
  cmd=""
  skip_next=0
  for arg in "$@"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    if _is_value_flag "$arg"; then
      skip_next=1
      continue
    fi
    case "$arg" in
      info|backup|restore|help|-h|--help)
        if [ -z "$cmd" ]; then
          cmd="$arg"
        fi
        ;;
      *)
        ;;
    esac
  done

  if [ -z "$cmd" ]; then
    usage
    exit 1
  fi

  extract_config_file "$@"
  CONFIG_FILE="$_EXTRACTED_CONFIG_FILE"
  INSTANCE_NAME="$_EXTRACTED_INSTANCE"
  resolve_config_instance
  parse_common_args "$@"

  case "$cmd" in
    info)
      cmd_info
      ;;
    backup)
      cmd_backup
      ;;
    restore)
      cmd_restore
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

if [ "${DB_OPS_TEST:-0}" != "1" ]; then
  main "$@"
fi
