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

# Rejects identifiers (database/table/column names) that contain a backtick
# character. MySQL identifiers quoted with backticks require any embedded
# backtick to be doubled; rather than trying to escape/reconstruct that, we
# simply refuse any identifier containing a backtick outright. A legitimate
# database/table/column name in normal operational use will essentially
# never contain one, so rejecting it is safe and closes off a class of SQL
# injection where a crafted name could break out of the backtick-quoted
# identifier context.
validate_identifier() {
  case "$1" in
    *'`'*) die "Invalid identifier (contains backtick): $1" ;;
  esac
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
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
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
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
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
    "--ssl" \
    "--skip-ssl-verify-server-cert" \
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

# Resolves which databases to operate on based on --all-databases / --database
# flags, and validates the resulting list is non-empty. Echoes the newline
# separated list of database names, one per line, to stdout.
resolve_target_databases() {
  target_databases=""
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
    tables=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';")
    views=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='VIEW';")
    routines=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${db}';")
    triggers=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${db}';")
    events=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='${db}';")
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
    out_dir="backup_${timestamp}"
  fi
  mkdir -p "$out_dir"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    echo "Backing up database: $db"
    backup_one_database "$db" "$out_dir/${db}.sql.gz"
  done

  echo "Backup complete: $out_dir"
}

backup_one_database() {
  db="$1"
  out_file="$2"
  tmp_sql="$(mktemp)"

  db_mysqldump --no-data --routines --triggers --events "$db" >> "$tmp_sql" \
    || die "Schema dump failed for database: $db"

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
# are redirected to <column>_tmp during data import. Invoked as:
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
          col = "`" colname "_tmp`"
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
  gzip -dc "$archive" > "$tmp_sql"

  db_mysql -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\`;" < /dev/null \
    || die "Failed to (re)create database: $db"

  tmp_sql_filtered="$(mktemp)"
  grep -Ev '(SET @OLD_[A-Za-z_]+=|SET [A-Za-z_]+=@OLD_[A-Za-z_]+)' "$tmp_sql" > "$tmp_sql_filtered"

  schema_sql="$(mktemp)"
  data_sql="$(mktemp)"
  awk -v schema_out="$schema_sql" -v data_out="$data_sql" '
    /^INSERT INTO / { in_insert = 1 }
    in_insert { print >> data_out; next }
    { print >> schema_out }
  ' "$tmp_sql_filtered"

  { printf '%s\n' "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;"; cat "$schema_sql"; printf '%s\n' "COMMIT;"; } \
    | db_mysql "$db" || die "Failed to import schema for database: $db"

  map_raw="$(mktemp)"
  map_file="$(mktemp)"
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
    db_mysql "$db" -e "ALTER TABLE \`${tbl}\` ADD COLUMN \`${col}_tmp\` ${coltype} NULL;" < /dev/null \
      || die "Failed to add temp column ${col}_tmp on ${tbl}"
  done < "$map_raw"

  if [ -s "$map_file" ]; then
    filtered_data_sql="$(mktemp)"
    gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql" > "$filtered_data_sql"
    { printf '%s\n' "SET FOREIGN_KEY_CHECKS=0; SET UNIQUE_CHECKS=0; SET AUTOCOMMIT=0;"; cat "$filtered_data_sql"; printf '%s\n' "COMMIT;"; } \
      | db_mysql "$db" || die "Failed to import data for database: $db"
    rm -f "$filtered_data_sql"

    while IFS="$(printf '\t')" read -r tbl col; do
      [ -n "$tbl" ] || continue
      db_mysql "$db" -e "ALTER TABLE \`${tbl}\` DROP COLUMN \`${col}_tmp\`;" < /dev/null \
        || die "Failed to drop temp column ${col}_tmp on ${tbl}"
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
  --dir <path>           Base directory to place the timestamped backup_<ts>/
                         folder in (default: current directory)

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
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

if [ "${DB_OPS_TEST:-0}" != "1" ]; then
  main "$@"
fi
