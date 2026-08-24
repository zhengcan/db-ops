#!/bin/sh
# pg-ops.sh - single-file PostgreSQL backup/restore tool for bare Alpine.
# Sibling tool to my-ops.sh (MySQL); mirrors its architecture, CLI, dbs.conf
# format, and safety conventions. Key differences from my-ops.sh:
#   - Password is never passed via CLI flag/env var to psql/pg_dump; a
#     temporary .pgpass-format file (PGPASSFILE) is used instead.
#   - TLS is requested via PGSSLMODE=require (encrypts, does not verify the
#     server certificate -- the libpq analogue of
#     --ssl --skip-ssl-verify-server-cert).
#   - restore cannot DROP/CREATE the database it is connected to, so it
#     always connects to the "postgres" maintenance database for the
#     DROP DATABASE / CREATE DATABASE step, then reconnects to the target
#     database to import the dump.
#   - Generated columns need no __tmp staging column dance: pg_dump already
#     omits generated column values from COPY/INSERT data while preserving
#     the GENERATED ALWAYS AS (...) definition in CREATE TABLE, so a plain
#     import recomputes them automatically.
set -eu

# ===================== Config defaults =====================
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_DATABASE="${DB_DATABASE:-}"
DB_ALL_DATABASES=0
FORCE=0
BACKUP_DIR=""
CONFIG_FILE=""
INSTANCE_NAME=""
CONFIG_INSTANCE_TYPE=""
DEFAULT_CONFIG_FILE="dbs.conf"

_TMP_PGPASS_FILE=""
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
#
# This INI parser (and load_config_instance/resolve_config_instance below)
# is intentionally duplicated verbatim from my-ops.sh rather than shared via
# a common lib file: both scripts must remain single-file and independently
# distributable (no sourcing one from the other, no shared lib dependency).
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
#      must be `pg`, or this dies (this is the one point where pg-ops.sh's
#      config validation diverges from my-ops.sh's, which requires `mysql`).
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
  [ "$type_lc" = "pg" ] \
    || die "Instance '$selected' has type=${CONFIG_INSTANCE_TYPE}, but pg-ops.sh only supports pg instances"

  # Record the actually-resolved instance name (covers both the
  # auto-selected single-instance case and an explicit --instance), so
  # callers like cmd_backup's default path naming can use it.
  INSTANCE_NAME="$selected"
}

# Validates identifiers (database/table/column names) with an allowlist:
# only letters, digits, and underscores are permitted. PostgreSQL's actual
# identifier rules are more permissive (quoted identifiers can contain
# almost anything), but this deliberately conservative allowlist -- the
# same one my-ops.sh uses -- closes off SQL injection risk in the several
# double-quoted-identifier and single-quoted-string-literal contexts this
# script interpolates identifiers into, without having to reason about each
# context's specific escape character. Legitimate database/table/column
# names in normal operational use consist of letters, digits, and
# underscores, so this is safe for real-world use.
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
  # shellcheck disable=SC2086
  if [ -n "$_TMP_FILES_TO_CLEAN" ]; then
    rm -f $_TMP_FILES_TO_CLEAN 2>/dev/null || true
  fi
}
trap cleanup_common EXIT INT TERM

ensure_dependencies() {
  need_install=0
  command -v psql >/dev/null 2>&1 || need_install=1
  command -v pg_dump >/dev/null 2>&1 || need_install=1
  command -v gzip >/dev/null 2>&1 || need_install=1

  if [ "$need_install" -eq 1 ]; then
    command -v apk >/dev/null 2>&1 || die "apk not found; cannot auto-install dependencies"
    apk add --no-cache postgresql-client gzip >&2 \
      || die "Failed to install dependencies via apk"
  fi

  command -v psql >/dev/null 2>&1 || die "Required command still missing after install: psql"
  command -v pg_dump >/dev/null 2>&1 || die "Required command still missing after install: pg_dump"
  command -v gzip >/dev/null 2>&1 || die "Required command still missing after install: gzip"
}

# ===================== Connection helpers =====================

# Writes a temporary .pgpass-format file containing the password, so it
# never appears in the process argument list or environment variables that
# other processes on the host could observe. Format (per libpq docs):
#   hostname:port:database:username:password
# with ':' and '\' in any field escaped as '\:' and '\\'. The database
# field is always '*' (wildcard) since a single connection profile is used
# both for the "postgres" maintenance database (restore's DROP/CREATE step)
# and the target database. Sets _TMP_PGPASS_FILE.
make_pgpass_file() {
  _TMP_PGPASS_FILE="$(mktemp)"
  register_tmp_file "$_TMP_PGPASS_FILE"
  esc_host=$(printf '%s' "$DB_HOST" | sed 's/\\/\\\\/g; s/:/\\:/g')
  esc_port=$(printf '%s' "$DB_PORT" | sed 's/\\/\\\\/g; s/:/\\:/g')
  esc_user=$(printf '%s' "$DB_USER" | sed 's/\\/\\\\/g; s/:/\\:/g')
  esc_pw=$(printf '%s' "$DB_PASSWORD" | sed 's/\\/\\\\/g; s/:/\\:/g')
  printf '%s:%s:*:%s:%s\n' "$esc_host" "$esc_port" "$esc_user" "$esc_pw" > "$_TMP_PGPASS_FILE"
}

# Each db_* wrapper below prepends the common connection flags to its
# positional parameters via `set --` (rather than an unquoted command
# substitution) so that values such as DB_HOST containing spaces are
# forwarded as single arguments, not word-split. The first positional
# parameter is always the database name to connect to (e.g. "postgres" for
# maintenance-database operations, or the target database name).
#
# PGSSLMODE=require encrypts the connection without verifying the server
# certificate, tolerating self-signed certs -- the libpq analogue of
# my-ops.sh's `--ssl --skip-ssl-verify-server-cert`. --no-password prevents
# psql/pg_dump from ever falling back to an interactive password prompt,
# forcing reliance on PGPASSFILE (fails fast and loud instead of hanging if
# the pgpass file is missing/wrong).
db_psql() {
  target_db="$1"; shift
  [ -n "$_TMP_PGPASS_FILE" ] || make_pgpass_file
  PGPASSFILE="$_TMP_PGPASS_FILE" PGSSLMODE=require psql \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --dbname="${target_db}" \
    --no-password \
    -v ON_ERROR_STOP=1 \
    "$@"
}

db_pgdump() {
  target_db="$1"; shift
  [ -n "$_TMP_PGPASS_FILE" ] || make_pgpass_file
  PGPASSFILE="$_TMP_PGPASS_FILE" PGSSLMODE=require pg_dump \
    --host="${DB_HOST}" \
    --port="${DB_PORT}" \
    --username="${DB_USER}" \
    --dbname="${target_db}" \
    --no-password \
    "$@"
}

check_connection() {
  db_psql postgres -tAc "SELECT 1;" >/dev/null 2>&1 \
    || die "Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT}"
}

list_all_databases() {
  db_psql postgres -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;"
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
    tables=$(db_psql "$db" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';") \
      || die "Failed to query object counts for database: $db"
    views=$(db_psql "$db" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='VIEW';") \
      || die "Failed to query object counts for database: $db"
    functions=$(db_psql "$db" -tAc "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname='public';") \
      || die "Failed to query object counts for database: $db"
    triggers=$(db_psql "$db" -tAc "SELECT COUNT(DISTINCT trigger_name) FROM information_schema.triggers WHERE trigger_schema='public';") \
      || die "Failed to query object counts for database: $db"
    sequences=$(db_psql "$db" -tAc "SELECT COUNT(*) FROM pg_sequences WHERE schemaname='public';") \
      || die "Failed to query object counts for database: $db"
    echo "  Tables:               $tables"
    echo "  Views:                $views"
    echo "  Functions:            $functions"
    echo "  Triggers:             $triggers"
    echo "  Sequences:            $sequences"
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
    out_dir="backup/pg/${safe_label}/${timestamp}"
  fi
  mkdir -p "$out_dir"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    table_count=$(db_psql "$db" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';") \
      || die "Failed to query table count for database: $db"
    echo "Backing up database: $db (${table_count} table(s))..."
    backup_one_database "$db" "$out_dir/${db}.sql.gz"
    echo "Completed database: $db"
  done

  echo "Backup complete: $out_dir"
}

# Runs a single plain-text pg_dump for $db into $out_file (gzip-compressed).
# A single pass covers table structure, data, views, functions, triggers,
# and sequences -- unlike my-ops.sh, no separate schema-only/data-only
# passes are needed, because pg_dump's default plain-text output is already
# a complete, self-consistent single file (and PostgreSQL has no schema/data
# separation concern equivalent to MySQL's --routines SHOW PACKAGE STATUS
# misdetection issue).
backup_one_database() {
  db="$1"
  out_file="$2"
  tmp_sql="$(mktemp)"
  register_tmp_file "$tmp_sql"

  db_pgdump "$db" > "$tmp_sql" || die "Backup failed for database: $db"

  gzip -c "$tmp_sql" > "$out_file"
  rm -f "$tmp_sql"
}

# ===================== restore subcommand =====================
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

# Restores a single database. PostgreSQL cannot DROP the database a
# connection is currently using, so this is unavoidably a two-phase
# connection sequence:
#   1. Connect to the "postgres" maintenance database and DROP+CREATE the
#      target database there.
#   2. Disconnect, then open a fresh connection to the (now newly created,
#      empty) target database and import the dump into it.
# Generated columns need no staging-column workaround here (unlike
# my-ops.sh's __tmp dance): pg_dump's plain-text output already excludes
# generated column values from the data it emits while keeping the
# GENERATED ALWAYS AS (...) clause in CREATE TABLE, so a straight import
# lets PostgreSQL recompute them itself.
restore_one_database() {
  db="$1"
  archive="$2"
  tmp_sql="$(mktemp)"
  register_tmp_file "$tmp_sql"
  gzip -dc "$archive" > "$tmp_sql" || die "Failed to decompress backup archive: $archive"

  # Phase 1: connect to the maintenance database to drop/recreate the
  # target database (never connect directly to $db for this step).
  db_psql postgres -c "DROP DATABASE IF EXISTS \"${db}\";" < /dev/null \
    || die "Failed to drop database: $db"
  db_psql postgres -c "CREATE DATABASE \"${db}\";" < /dev/null \
    || die "Failed to create database: $db"

  # Phase 2: connect to the freshly created target database and import.
  db_psql "$db" -f "$tmp_sql" < /dev/null \
    || die "Failed to import data for database: $db"

  rm -f "$tmp_sql"
}

# ===================== usage & main =====================
usage() {
  cat <<'EOF'
Usage: pg-ops.sh <command> [options]
       pg-ops.sh [options] <command> [options]

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
  --host <host>         PostgreSQL host (default 127.0.0.1)
  --port <port>         PostgreSQL port (default 5432)
  --user <user>         PostgreSQL user (default postgres)
  --password <password> PostgreSQL password (prefer DB_PASSWORD env var)

backup options:
  --database <db1,db2>  Comma-separated list of databases to back up
  --all-databases        Back up all non-template, non-maintenance databases
  --dir <path>           Base directory to place the timestamped backup_<ts>/
                         folder in (default: backup/pg/<host>/<timestamp>/
                         under the current directory, where <host> is the
                         sanitized --host value)

restore options:
  --dir <backup_dir>     Backup directory produced by 'backup'
  --database <db1,db2>   Comma-separated list of databases to restore
                         (--all-databases is not supported for restore)
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
