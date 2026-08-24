#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../pg-ops.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/pg_query_aware"
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
    --host h --port 5432 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK"* ]]
  [[ "$output" == *"Database: mydb"* ]]
  [[ "$output" == *"Tables:               3"* ]]
  [[ "$output" == *"Views:                1"* ]]
  [[ "$output" == *"Functions:            2"* ]]
  [[ "$output" == *"Triggers:             1"* ]]
  [[ "$output" == *"Sequences:            1"* ]]
}

@test "info fails with a clear error when no database is specified" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 5432 --user u --password p
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}

@test "info fails with a clear error when --database resolves to an empty list" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 5432 --user u --password p --database ","
  [ "$status" -eq 1 ]
  [[ "$output" == *"No databases to process"* ]]
}

@test "info fails with a clear error when both --database and --all-databases are given" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 5432 --user u --password p --database mydb --all-databases
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot combine --database and --all-databases"* ]]
}

@test "info fails with a clear error when an object-count query fails" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" PSQL_EXIT_CODE=1 "$SCRIPT" info \
    --host h --port 5432 --user u --password p --database mydb
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to query object counts"* ]]
}

@test "info --all-databases reports a section for every discovered database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 5432 --user u --password p --all-databases
  [ "$status" -eq 0 ]
  [[ "$output" == *"Database: db_one"* ]]
  [[ "$output" == *"Database: db_two"* ]]
}

@test "backup creates a timestamped directory with one gz file per database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 5432 --user u --password p --database mydb
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$WORK_DIR"/backup/pg/h/* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]

  dump="$(zcat "$backup_dir/mydb.sql.gz")"
  [[ "$dump" == *"PG_DUMP MARKER db=mydb"* ]]

  grep -q -- "--dbname=mydb" "$STUB_LOG"
}

@test "backup prints per-database progress with table count and completion" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 5432 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backing up database: mydb (3 table(s))"* ]]
  [[ "$output" == *"Completed database: mydb"* ]]
}

@test "backup --dir places the timestamped directory under the given base path" {
  custom_base="$WORK_DIR/custom_backups"
  mkdir -p "$custom_base"
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 5432 --user u --password p --database mydb --dir "$custom_base"
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$custom_base"/backup_* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]
  [ -z "$(ls -d "$WORK_DIR"/backup_* 2>/dev/null)" ]
  [ -z "$(ls -d "$WORK_DIR"/backup 2>/dev/null)" ]
}

@test "backup --all-databases backs up every discovered database into separate files" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 5432 --user u --password p --all-databases
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$WORK_DIR"/backup/pg/h/* | tail -1)"
  [ -f "$backup_dir/db_one.sql.gz" ]
  [ -f "$backup_dir/db_two.sql.gz" ]
  zcat "$backup_dir/db_one.sql.gz" | grep -q "db=db_one"
  zcat "$backup_dir/db_two.sql.gz" | grep -q "db=db_two"
}

@test "list_all_databases excludes postgres/template0/template1 from --all-databases" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 5432 --user u --password p --all-databases
  [ "$status" -eq 0 ]
  grep -- "pg_database" "$STUB_LOG" | grep -q "datistemplate = false"
}

@test "backup without --dir uses backup/pg/<host>/<timestamp>/ as the default path" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host pg.internal --port 5432 --user u --password p --database mydb
  [ "$status" -eq 0 ]

  matches=("$WORK_DIR"/backup/pg/pg.internal/*/mydb.sql.gz)
  [ -f "${matches[0]}" ]
}

@test "backup without --dir uses the dbs.conf instance name (not the host) when a config instance is resolved" {
  cd "$WORK_DIR"
  cat > dbs.conf <<'EOF'
[prod]
type = pg
host = pg.internal
port = 5432
user = u
password = p
database = mydb
EOF
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup
  [ "$status" -eq 0 ]

  matches=("$WORK_DIR"/backup/pg/prod/*/mydb.sql.gz)
  [ -f "${matches[0]}" ]
  [ ! -d "$WORK_DIR/backup/pg/pg.internal" ]
}

@test "backup fails clearly when pg_dump fails for a database" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" PGDUMP_EXIT_CODE=1 "$SCRIPT" backup \
    --host h --port 5432 --user u --password p --database mydb
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup failed for database: mydb"* ]]
}
