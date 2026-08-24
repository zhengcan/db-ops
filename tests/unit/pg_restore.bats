#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../pg-ops.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg_query_aware"
  STUB_LOG="$(mktemp)"
  WORK_DIR="$(mktemp -d)"

  cat > "$WORK_DIR/plain.sql" <<'EOF'
CREATE TABLE audit_log (id INT, message VARCHAR(255));
INSERT INTO audit_log (id, message) VALUES (1,'hello');
EOF
  gzip -c "$WORK_DIR/plain.sql" > "$WORK_DIR/plain_backup.sql.gz"

  cat > "$WORK_DIR/gencol.sql" <<'EOF'
CREATE TABLE products (id INT, name VARCHAR(100), price NUMERIC(10,2), price_with_tax NUMERIC(10,2) GENERATED ALWAYS AS (price * 1.1) STORED);
INSERT INTO products (id, name, price) VALUES (1,'Widget',9.99);
EOF
  gzip -c "$WORK_DIR/gencol.sql" > "$WORK_DIR/gencol_backup.sql.gz"

  mkdir -p "$WORK_DIR/backup_20260101_000000"
  cp "$WORK_DIR/plain_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/plaindb.sql.gz"
  cp "$WORK_DIR/gencol_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/gencoldb.sql.gz"
}

teardown() {
  rm -f "$STUB_LOG"
  rm -rf "$WORK_DIR"
}

run_restore() {
  ( cd "$WORK_DIR" && env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$@" )
}

@test "restore requires --dir" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p --database plaindb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --dir"* ]]
}

@test "restore requires an explicit --database" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}

@test "restore rejects --all-databases" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --all-databases --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore does not support --all-databases"* ]]
}

@test "restore rejects combining --database and --all-databases with the more general error" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --database plaindb --all-databases --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot combine --database and --all-databases"* ]]
}

@test "restore dies when the backup file for a database is missing" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --database nosuchdb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup file not found"* ]]
}

@test "restore aborts without --force when the user declines confirmation" {
  run run_restore env DB_OPS_TEST_CONFIRM_STDIN=1 bash -c "echo n | \"$SCRIPT\" restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --database plaindb"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted by user"* ]]
}

@test "restore's confirm() reads from /dev/tty, not the outer multi-database loop's stdin (regression guard, mirrors my-ops.sh)" {
  # confirm() must never share stdin with cmd_restore's
  # `printf '%s\n' "$databases" | while read -r db; do ...` loop, or its
  # `read -r reply` would silently consume the *next* database name off the
  # pipe instead of a real answer. Verified the same way common.bats/
  # pg_common.bats verify it directly: with DB_OPS_TEST_CONFIRM_STDIN unset,
  # confirm() must attempt to read from /dev/tty (which fails/is unavailable
  # in this sandbox), never succeeding by accident via stdin.
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; FORCE=0; echo y | confirm "Proceed?"' </dev/null
  [ "$status" -ne 0 ]
}

@test "restore imports a database with no generated columns" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p \
    --dir backup_20260101_000000 --database plaindb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: plaindb"* ]]
}

@test "restore imports a database with generated columns with no __tmp staging (unlike my-ops.sh)" {
  STDIN_CAPTURE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_STDIN_CAPTURE="$STDIN_CAPTURE" \
    bash -c "cd '$WORK_DIR' && '$SCRIPT' restore --host h --port 5432 --user u --password p --dir backup_20260101_000000 --database gencoldb --force"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: gencoldb"* ]]
  ! grep -q "__tmp" "$STUB_LOG"
  ! grep -q "ADD COLUMN" "$STUB_LOG"
  ! grep -q "DROP COLUMN" "$STUB_LOG"
  grep -q "GENERATED ALWAYS AS" "$STDIN_CAPTURE"
  rm -f "$STDIN_CAPTURE"
}

@test "restore processes every database in a comma-separated --database list" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p \
    --dir backup_20260101_000000 --database plaindb,gencoldb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: plaindb"* ]]
  [[ "$output" == *"Restored database: gencoldb"* ]]
}

@test "restore connects to the 'postgres' maintenance database for DROP/CREATE, never directly to the target db, before reconnecting to the target db to import" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p \
    --dir backup_20260101_000000 --database plaindb --force
  [ "$status" -eq 0 ]

  grep -q -- "--dbname=postgres" "$STUB_LOG"
  grep -q "DROP DATABASE IF EXISTS \"plaindb\"" "$STUB_LOG"
  grep -q "CREATE DATABASE \"plaindb\"" "$STUB_LOG"

  # The DROP/CREATE calls must have been issued against the "postgres"
  # maintenance database connection, not the target database.
  drop_line="$(grep "DROP DATABASE" "$STUB_LOG")"
  [[ "$drop_line" == *"--dbname=postgres"* ]]
  create_line="$(grep "CREATE DATABASE" "$STUB_LOG")"
  [[ "$create_line" == *"--dbname=postgres"* ]]

  # The final import call (-f <file>) must connect to the target db, not
  # to the "postgres" maintenance db.
  import_line="$(grep -- "-f " "$STUB_LOG" | tail -1)"
  [[ "$import_line" == *"--dbname=plaindb"* ]]

  # Sequence check: the postgres-db calls must precede the target-db import
  # call in the log (two-phase connection order).
  postgres_call_line_no="$(grep -n -- "--dbname=postgres" "$STUB_LOG" | tail -1 | cut -d: -f1)"
  target_call_line_no="$(grep -n -- "-f " "$STUB_LOG" | tail -1 | cut -d: -f1)"
  [ "$postgres_call_line_no" -lt "$target_call_line_no" ]
}

@test "restore fails clearly when the drop/create step against the maintenance database fails" {
  run run_restore env PSQL_EXIT_CODE=1 "$SCRIPT" restore --host h --port 5432 --user u --password p \
    --dir backup_20260101_000000 --database plaindb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to drop database: plaindb"* ]]
}

@test "restore validates database names before using them" {
  run run_restore "$SCRIPT" restore --host h --port 5432 --user u --password p \
    --dir backup_20260101_000000 --database 'evil"; DROP DATABASE postgres; --' --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid identifier"* ]]
}
