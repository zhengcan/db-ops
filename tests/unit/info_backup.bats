#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/query_aware"
  STUB_LOG="$(mktemp)"
  WORK_DIR="$(mktemp -d)"
}

teardown() {
  rm -f "$STUB_LOG"
  rm -rf "$WORK_DIR"
}

@test "info reports connection OK and object counts for an explicit database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK"* ]]
  [[ "$output" == *"Database: mydb"* ]]
  [[ "$output" == *"Tables:               3"* ]]
  [[ "$output" == *"Views:                1"* ]]
  [[ "$output" == *"Routines (proc/func): 2"* ]]
  [[ "$output" == *"Triggers:             1"* ]]
  [[ "$output" == *"Events:               1"* ]]
}

@test "info fails with a clear error when no database is specified" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}

@test "info fails with a clear error when --database resolves to an empty list" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p --database ","
  [ "$status" -eq 1 ]
  [[ "$output" == *"No databases to process"* ]]
}

@test "info fails with a clear error when both --database and --all-databases are given" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p --database mydb --all-databases
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot combine --database and --all-databases"* ]]
}

@test "info fails with a clear error when an object-count query fails" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" MYSQL_EXIT_CODE=1 "$SCRIPT" info \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to query object counts"* ]]
}

@test "info --all-databases reports a section for every discovered database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p --all-databases
  [ "$status" -eq 0 ]
  [[ "$output" == *"Database: db_one"* ]]
  [[ "$output" == *"Database: db_two"* ]]
}

@test "backup creates a timestamped directory with one gz file per database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$WORK_DIR"/backup_* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]

  dump="$(zcat "$backup_dir/mydb.sql.gz")"
  [[ "$dump" == *"SCHEMA MARKER db=mydb"* ]]
  [[ "$dump" == *"DATA MARKER db=mydb"* ]]
  grep -q -- "--hex-blob" "$STUB_LOG"
  grep -q -- "--single-transaction" "$STUB_LOG"
  grep -q -- "--complete-insert" "$STUB_LOG"
  grep -q -- "--skip-extended-insert" "$STUB_LOG"
  grep -q -- "--routines" "$STUB_LOG"
  grep -q -- "--triggers" "$STUB_LOG"
  grep -q -- "--events" "$STUB_LOG"

  data_pass_line="$(grep -- "--no-create-info" "$STUB_LOG")"
  [[ "$data_pass_line" == *"--skip-triggers"* ]]
  [[ "$data_pass_line" == *"--skip-routines"* ]]
  [[ "$data_pass_line" == *"--skip-events"* ]]
}

@test "backup --dir places the timestamped directory under the given base path" {
  custom_base="$WORK_DIR/custom_backups"
  mkdir -p "$custom_base"
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb --dir "$custom_base"
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$custom_base"/backup_* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]
  # Nothing should have been created directly under WORK_DIR itself.
  [ -z "$(ls -d "$WORK_DIR"/backup_* 2>/dev/null)" ]
}

@test "backup --all-databases backs up every discovered database into separate files" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --all-databases
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$WORK_DIR"/backup_* | tail -1)"
  [ -f "$backup_dir/db_one.sql.gz" ]
  [ -f "$backup_dir/db_two.sql.gz" ]
  zcat "$backup_dir/db_one.sql.gz" | grep -q "db=db_one"
  zcat "$backup_dir/db_two.sql.gz" | grep -q "db=db_two"
}
