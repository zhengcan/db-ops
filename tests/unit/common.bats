#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
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
  parse_common_args --host myhost --port 3307 --user myuser --password mypass
  [ "$DB_HOST" = "myhost" ]
  [ "$DB_PORT" = "3307" ]
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
}

@test "extract_config_file dies with a clear error when --config's value is missing" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; extract_config_file --config'
  [ "$status" -eq 1 ]
  [[ "$output" == *"--config requires a value"* ]]
}

@test "load_config sources a KEY=VALUE config file" {
  cfg="$(mktemp)"
  printf 'DB_HOST=cfghost\nDB_USER=cfguser\n' > "$cfg"
  CONFIG_FILE="$cfg"
  load_config
  [ "$DB_HOST" = "cfghost" ]
  [ "$DB_USER" = "cfguser" ]
  rm -f "$cfg"
}

@test "load_config dies when config file is missing" {
  CONFIG_FILE="/nonexistent/file.cfg"
  run load_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
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
  # Even though the outer pipe supplies "y" on stdin, confirm() must not
  # consume it; without a real controlling terminal available, reading from
  # /dev/tty should fail, proving stdin is not being aliased into confirm().
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; FORCE=0; echo y | confirm "Proceed?"' </dev/null
  [ "$status" -ne 0 ]
}

@test "db_mysqladmin invokes mysqladmin with required SSL flags and connection args" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" \
    sh -c ". '$SCRIPT'; DB_HOST=testhost DB_PORT=3306 DB_USER=testuser DB_PASSWORD=testpass db_mysqladmin ping"
  [ "$status" -eq 0 ]
  grep -qE -- '(^| )--ssl( |$)' "$STUB_LOG"
  grep -q -- "--skip-ssl-verify-server-cert" "$STUB_LOG"
  grep -q -- "--host=testhost" "$STUB_LOG"
  grep -q -- "--port=3306" "$STUB_LOG"
  grep -q -- "--user=testuser" "$STUB_LOG"
  grep -q -- "ping" "$STUB_LOG"
  rm -f "$STUB_LOG"
}

@test "make_defaults_file writes password into a client section file with mode 600" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c "
    . '$SCRIPT'
    DB_PASSWORD=testpass make_defaults_file
    grep -q '^password=\"testpass\"\$' \"\$_TMP_DEFAULTS_FILE\" || exit 1
    perms=\$(stat -f '%Lp' \"\$_TMP_DEFAULTS_FILE\" 2>/dev/null || stat -c '%a' \"\$_TMP_DEFAULTS_FILE\")
    [ \"\$perms\" = '600' ] || exit 1
  "
  [ "$status" -eq 0 ]
}

@test "make_defaults_file quotes a password containing # so it is not truncated as a comment" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c "
    . '$SCRIPT'
    DB_PASSWORD='secret#123' make_defaults_file
    grep -q '^password=\"secret#123\"\$' \"\$_TMP_DEFAULTS_FILE\" || exit 1
  "
  [ "$status" -eq 0 ]
}

@test "make_defaults_file escapes embedded double quotes and backslashes in the password" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c '
    . "'"$SCRIPT"'"
    DB_PASSWORD='"'"'p"a\b'"'"' make_defaults_file
    grep -q '"'"'^password="p\\"a\\\\b"$'"'"' "$_TMP_DEFAULTS_FILE" || exit 1
  '
  [ "$status" -eq 0 ]
}

@test "register_tmp_file adds a path to the cleanup list and chmods it 600" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
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

@test "cleanup_common removes all registered temp files, not just the defaults file" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
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
  # Simulate a mid-restore failure (DROP/CREATE DATABASE call fails) and
  # verify that temp files registered before the failure point (tmp_sql,
  # tmp_sql_filtered) are still cleaned up via the EXIT trap, not left
  # behind on disk. register_tmp_file is overridden after sourcing to also
  # log every registered path to TRACK_FILE, so the outer assertion can
  # check that none of the files it saw still exist once the process
  # (which dies via `die` -> `exit 1`, triggering the EXIT trap) has ended.
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/query_aware"
  WORK_DIR="$(mktemp -d)"
  printf 'CREATE TABLE t (id INT);\n' > "$WORK_DIR/plain.sql"
  gzip -c "$WORK_DIR/plain.sql" > "$WORK_DIR/db.sql.gz"

  TRACK_FILE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 MYSQL_EXIT_CODE=1 TRACK_FILE="$TRACK_FILE" bash -c '
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
  # Sanity check: at least one file must actually have been tracked,
  # otherwise this test would trivially pass without exercising cleanup.
  [ -s "$TRACK_FILE" ]

  rm -rf "$WORK_DIR" "$TRACK_FILE"
}

@test "check_connection fails when mysqladmin ping stub returns error" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 MYSQLADMIN_EXIT_CODE=1 STUB_LOG="$(mktemp)" \
    sh -c ". '$SCRIPT'; DB_HOST=h DB_PORT=1 DB_USER=u DB_PASSWORD=p check_connection"
  [ "$status" -eq 1 ]
}

@test "db_mysql passes a DB_HOST containing spaces as a single argument" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" \
    sh -c '. "'"$SCRIPT"'"; DB_HOST="my host" DB_PORT=3306 DB_USER=testuser DB_PASSWORD=testpass db_mysql -e "SELECT 1"'
  [ "$status" -eq 0 ]
  grep -q -- "ARG:\[--host=my host\]" "$STUB_LOG"
  ! grep -q -- "ARG:\[--host=my\]" "$STUB_LOG"
  rm -f "$STUB_LOG"
}

@test "main loads config before parsing CLI args so CLI args take precedence" {
  cfg="$(mktemp)"
  printf 'DB_HOST=cfghost\n' > "$cfg"

  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; main help --config "'"$cfg"'" --host clihost; echo "DB_HOST=$DB_HOST"'
  rm -f "$cfg"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DB_HOST=clihost"* ]]
}

@test "ensure_dependencies installs missing packages via apk" {
  fake_bin="$(mktemp -d)"
  cp "$BATS_TEST_DIRNAME/stubs/apk" "$fake_bin/apk"
  chmod +x "$fake_bin/apk"
  STUB_LOG="$(mktemp)"

  run env PATH="$fake_bin:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" sh -c ". '$SCRIPT'; ensure_dependencies"

  [ "$status" -eq 0 ]
  grep -q "apk add --no-cache mariadb-client mariadb-connector-c gzip gawk" "$STUB_LOG"
  [ -x "$fake_bin/mysql" ]
  rm -rf "$fake_bin" "$STUB_LOG"
}

@test "validate_identifier accepts alphanumeric and underscore names" {
  run validate_identifier "my_db_1"
  [ "$status" -eq 0 ]
}

@test "validate_identifier accepts real-world seed schema identifiers" {
  run validate_identifier "products"
  [ "$status" -eq 0 ]
  run validate_identifier "price_with_tax"
  [ "$status" -eq 0 ]
  run validate_identifier "testdb2"
  [ "$status" -eq 0 ]
  run validate_identifier "audit_log"
  [ "$status" -eq 0 ]
}

@test "validate_identifier rejects identifiers containing a backtick" {
  run validate_identifier 'evil`; DROP DATABASE mysql; --'
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"Invalid identifier"* ]]
}

@test "validate_identifier rejects identifiers containing a single quote" {
  run validate_identifier "foo' OR '1'='1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
  [[ "$output" == *"Invalid identifier"* ]]
}

@test "validate_identifier rejects identifiers containing a semicolon or whitespace" {
  run validate_identifier "foo; DROP TABLE bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]

  run validate_identifier "foo bar"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR"* ]]
}

@test "resolve_target_databases dies when --database contains a backtick" {
  DB_DATABASE='ok_db,evil`db'
  DB_ALL_DATABASES=0
  run resolve_target_databases
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid identifier"* ]]
}

@test "resolve_target_databases dies when --database contains a single quote" {
  DB_DATABASE="ok_db,evil'db"
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
