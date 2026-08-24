#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../pg-ops.sh"
  export DB_OPS_TEST=1
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

@test "split_csv splits and trims a comma separated list" {
  result="$(split_csv "db1, db2 ,db3")"
  expected="$(printf 'db1\ndb2\ndb3')"
  [ "$result" = "$expected" ]
}

@test "split_csv returns single item for a list without commas" {
  result="$(split_csv "onlydb")"
  [ "$result" = "onlydb" ]
}

@test "parse_common_args sets DB_HOST DB_PORT DB_USER DB_PASSWORD" {
  parse_common_args --host myhost --port 5433 --user myuser --password mypass
  [ "$DB_HOST" = "myhost" ]
  [ "$DB_PORT" = "5433" ]
  [ "$DB_USER" = "myuser" ]
  [ "$DB_PASSWORD" = "mypass" ]
}

@test "parse_common_args sets --database" {
  parse_common_args --database db1,db2
  [ "$DB_DATABASE" = "db1,db2" ]
}

@test "parse_common_args sets --all-databases" {
  DB_ALL_DATABASES=0
  parse_common_args --all-databases
  [ "$DB_ALL_DATABASES" -eq 1 ]
}

@test "parse_common_args sets --force and --dir" {
  parse_common_args --force --dir /tmp/somebackup
  [ "$FORCE" -eq 1 ]
  [ "$BACKUP_DIR" = "/tmp/somebackup" ]
}

@test "parse_common_args dies with a clear error when an option's value is missing" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --host'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"--host requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --port'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --user'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--user requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --password'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--password requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --database'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--database requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --dir'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--dir requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --config'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--config requires a value"* ]]

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; parse_common_args --instance'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--instance requires a value"* ]]
}

@test "load_config_instance loads type/host/port/user/password/database for the given instance" {
  cfg="$(mktemp)"
  printf '[prod]\ntype = pg\nhost = cfghost\nport=5433\nuser=cfguser\npassword=cfgpass\ndatabase=cfgdb\n' > "$cfg"
  load_config_instance "$cfg" prod
  [ "$CONFIG_INSTANCE_TYPE" = "pg" ]
  [ "$DB_HOST" = "cfghost" ]
  [ "$DB_PORT" = "5433" ]
  [ "$DB_USER" = "cfguser" ]
  [ "$DB_PASSWORD" = "cfgpass" ]
  [ "$DB_DATABASE" = "cfgdb" ]
  rm -f "$cfg"
}

@test "resolve_config_instance dies when config file is missing" {
  CONFIG_FILE="/nonexistent/file.cfg"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "resolve_config_instance dies when the selected instance's type is not pg" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[main]
type = mysql
host = mysqlhost
EOF
  CONFIG_FILE="$cfg"
  run resolve_config_instance
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"mysql"* ]]
  [[ "$output" == *"pg"* ]]
  rm -f "$cfg"
}

@test "resolve_config_instance accepts type=pg (case-insensitive)" {
  cfg="$(mktemp)"
  cat > "$cfg" <<'EOF'
[main]
type = PG
host = pghost
EOF
  CONFIG_FILE="$cfg"
  resolve_config_instance
  [ "$DB_HOST" = "pghost" ]
  rm -f "$cfg"
}

@test "confirm returns success immediately when FORCE=1" {
  FORCE=1
  run confirm "Proceed?"
  [ "$status" -eq 0 ]
}

@test "confirm returns success when user answers y" {
  run bash -c 'export DB_OPS_TEST=1 DB_OPS_TEST_CONFIRM_STDIN=1; . "'"$SCRIPT"'"; FORCE=0; echo y | confirm "Proceed?"'
  [ "$status" -eq 0 ]
}

@test "confirm returns failure when user answers n" {
  run bash -c 'export DB_OPS_TEST=1 DB_OPS_TEST_CONFIRM_STDIN=1; . "'"$SCRIPT"'"; FORCE=0; echo n | confirm "Proceed?"'
  [ "$status" -eq 1 ]
}

@test "confirm reads from /dev/tty (not stdin) when not in test-stdin mode" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; FORCE=0; echo y | confirm "Proceed?"' </dev/null
  [ "$status" -ne 0 ]
}

@test "make_pgpass_file writes a host:port:*:user:password line with mode 600" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c "
    . '$SCRIPT'
    DB_HOST=myhost DB_PORT=5432 DB_USER=myuser DB_PASSWORD=mypass make_pgpass_file
    grep -q '^myhost:5432:\*:myuser:mypass\$' \"\$_TMP_PGPASS_FILE\" || exit 1
    perms=\$(stat -f '%Lp' \"\$_TMP_PGPASS_FILE\" 2>/dev/null || stat -c '%a' \"\$_TMP_PGPASS_FILE\")
    [ \"\$perms\" = '600' ] || exit 1
  "
  [ "$status" -eq 0 ]
}

@test "make_pgpass_file escapes colons and backslashes in field values" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c '
    . "'"$SCRIPT"'"
    DB_HOST=myhost DB_PORT=5432 DB_USER=myuser DB_PASSWORD="p:a\\b" make_pgpass_file
    grep -q "myhost:5432:\*:myuser:p\\\\:a\\\\\\\\b" "$_TMP_PGPASS_FILE" || exit 1
  '
  [ "$status" -eq 0 ]
}

@test "register_tmp_file adds a path to the cleanup list and chmods it 600" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c '
    . "'"$SCRIPT"'"
    f="$(mktemp)"
    chmod 644 "$f"
    register_tmp_file "$f"
    case "$_TMP_FILES_TO_CLEAN" in
      *"$f"*) : ;;
      *) exit 1 ;;
    esac
    perms=$(stat -f "%Lp" "$f" 2>/dev/null || stat -c "%a" "$f")
    [ "$perms" = "600" ] || exit 1
    rm -f "$f"
  '
  [ "$status" -eq 0 ]
}

@test "cleanup_common removes all registered temp files" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  f1="$(mktemp)"
  f2="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 F1="$f1" F2="$f2" sh -c '
    . "'"$SCRIPT"'"
    register_tmp_file "$F1"
    register_tmp_file "$F2"
    cleanup_common
  '
  [ "$status" -eq 0 ]
  [ ! -f "$f1" ]
  [ ! -f "$f2" ]
}

@test "restore_one_database cleans up registered temp files even when it dies mid-way" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg_query_aware"
  WORK_DIR="$(mktemp -d)"
  printf 'CREATE TABLE t (id INT);\n' > "$WORK_DIR/plain.sql"
  gzip -c "$WORK_DIR/plain.sql" > "$WORK_DIR/db.sql.gz"

  TRACK_FILE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 PSQL_EXIT_CODE=1 TRACK_FILE="$TRACK_FILE" bash -c '
    . "'"$SCRIPT"'"
    register_tmp_file() {
      _TMP_FILES_TO_CLEAN="$_TMP_FILES_TO_CLEAN $1"
      chmod 600 "$1"
      printf "%s\n" "$1" >> "$TRACK_FILE"
    }
    restore_one_database db "'"$WORK_DIR"'/db.sql.gz"
  '
  [ "$status" -ne 0 ]

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ ! -f "$f" ]
  done < "$TRACK_FILE"
  [ -s "$TRACK_FILE" ]

  rm -rf "$WORK_DIR" "$TRACK_FILE"
}

@test "check_connection fails when psql SELECT 1 stub returns error" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg_query_aware"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 PSQL_CONNECT_EXIT_CODE=1 STUB_LOG="$(mktemp)" \
    sh -c ". '$SCRIPT'; DB_HOST=h DB_PORT=1 DB_USER=u DB_PASSWORD=p check_connection"
  [ "$status" -eq 1 ]
}

@test "db_psql passes required connection flags and PGSSLMODE=require" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" \
    sh -c '. "'"$SCRIPT"'"; DB_HOST=testhost DB_PORT=5432 DB_USER=testuser DB_PASSWORD=testpass db_psql mydb -tAc "SELECT 1"'
  [ "$status" -eq 0 ]
  grep -q -- "--host=testhost" "$STUB_LOG"
  grep -q -- "--port=5432" "$STUB_LOG"
  grep -q -- "--username=testuser" "$STUB_LOG"
  grep -q -- "--dbname=mydb" "$STUB_LOG"
  grep -q -- "--no-password" "$STUB_LOG"
  rm -f "$STUB_LOG"
}

@test "db_psql passes a DB_HOST containing spaces as a single argument" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" \
    sh -c '. "'"$SCRIPT"'"; DB_HOST="my host" DB_PORT=5432 DB_USER=testuser DB_PASSWORD=testpass db_psql mydb -tAc "SELECT 1"'
  [ "$status" -eq 0 ]
  grep -q -- "ARG:\[--host=my host\]" "$STUB_LOG"
  ! grep -q -- "ARG:\[--host=my\]" "$STUB_LOG"
  rm -f "$STUB_LOG"
}

@test "main loads config before parsing CLI args so CLI args take precedence" {
  cfg="$(mktemp)"
  printf '[cfg]\ntype = pg\nhost = cfghost\n' > "$cfg"

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main help --config "'"$cfg"'" --host clihost; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=clihost"* ]]
}

@test "main accepts --config before the command" {
  cfg="$(mktemp)"
  printf '[cfg]\ntype = pg\nhost = cfghost\n' > "$cfg"

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'" help; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=cfghost"* ]]
}

@test "main sets common options placed before the command" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --host myhost --port 5433 --database mydb help; echo "DB_HOST=$DB_HOST DB_PORT=$DB_PORT DB_DATABASE=$DB_DATABASE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=myhost DB_PORT=5433 DB_DATABASE=mydb"* ]]
}

@test "main still supports the legacy command-first syntax" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main help --host myhost --database mydb; echo "DB_HOST=$DB_HOST DB_DATABASE=$DB_DATABASE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=myhost DB_DATABASE=mydb"* ]]
}

@test "main supports options mixed before and after the command" {
  cfg="$(mktemp)"
  printf '[cfg]\ntype = pg\nhost = cfghost\n' > "$cfg"

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'" help --database mydb --force; echo "DB_HOST=$DB_HOST DB_DATABASE=$DB_DATABASE FORCE=$FORCE"'
  rm -f "$cfg"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=cfghost DB_DATABASE=mydb FORCE=1"* ]]
}

@test "main prints usage and exits non-zero when only options are given with no command" {
  cfg="$(mktemp)"
  printf '[cfg]\ntype = pg\nhost = cfghost\n' > "$cfg"

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main --config "'"$cfg"'"'
  rm -f "$cfg"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "main does not mistake a flag value for the command even if it names a command" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg_query_aware"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=0 STUB_LOG="$STUB_LOG" "$SCRIPT" \
    --host backup --port 5432 --user u --password p info --database mydb
  rm -f "$STUB_LOG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK: u@backup:5432"* ]]
  [[ "$output" == *"Database: mydb"* ]]
}

@test "ensure_dependencies installs missing packages via apk" {
  fake_bin="$(mktemp -d)"
  cp "$BATS_TEST_DIRNAME/stubs/pg/apk" "$fake_bin/apk"
  chmod +x "$fake_bin/apk"
  STUB_LOG="$(mktemp)"

  # Restrict PATH to just the fake bin dir plus bare-minimum system core
  # utilities (not the host's normal $PATH), since a real psql/pg_dump may
  # already be installed on the developer/CI machine (e.g. via Homebrew),
  # which would make ensure_dependencies skip the apk-install path this
  # test is meant to exercise.
  run env PATH="$fake_bin:/usr/bin:/bin" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" sh -c ". '$SCRIPT'; ensure_dependencies"

  [ "$status" -eq 0 ]
  grep -q "apk add --no-cache postgresql-client gzip" "$STUB_LOG"
  [ -x "$fake_bin/psql" ]
  [ -x "$fake_bin/pg_dump" ]
  rm -rf "$fake_bin" "$STUB_LOG"
}

@test "validate_identifier accepts alphanumeric and underscore names" {
  run validate_identifier "my_db_1"
  [ "$status" -eq 0 ]
}

@test "validate_identifier rejects identifiers containing a double quote" {
  run validate_identifier 'evil"; DROP DATABASE postgres; --'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"Invalid identifier"* ]]
}

@test "validate_identifier rejects identifiers containing a single quote" {
  run validate_identifier "foo' OR '1'='1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "validate_identifier rejects identifiers containing a semicolon or whitespace" {
  run validate_identifier "foo; DROP TABLE bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]

  run validate_identifier "foo bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "resolve_target_databases dies when --database contains a double quote" {
  DB_DATABASE='ok_db,evil"db'
  DB_ALL_DATABASES=0
  run resolve_target_databases
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid identifier"* ]]
}

@test "resolve_target_databases dies when both --database and --all-databases are set" {
  DB_DATABASE="ok_db"
  DB_ALL_DATABASES=1
  run resolve_target_databases
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot combine --database and --all-databases"* ]]
}

@test "sanitize_path_component replaces path-unsafe characters in a hostname with underscores" {
  run env DB_OPS_TEST=1 bash -c '
    . "'"$SCRIPT"'"
    sanitize_path_component "evil/../host"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "evil_.._host" ]
}
