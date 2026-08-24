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

  backup_dir="$(ls -d "$WORK_DIR"/backup/mysql/h/* | tail -1)"
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

@test "backup prints per-database progress with table count and completion" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backing up database: mydb (3 table(s))"* ]]
  [[ "$output" == *"Completed database: mydb"* ]]
}

@test "backup does not print a noisy per-database warning on PACKAGE STATUS fallback (only the final summary)" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" MYSQLDUMP_ROUTINES_FAIL=1 "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  # The old, noisy per-database inline warning must be gone...
  [[ "$output" != *"could not be backed up: mariadb-dump misdetected"* ]]
  # ...but the single end-of-run summary must still be present.
  [[ "$output" == *"WARNING:"*"omitted due to a mariadb-dump version-detection issue"*"mydb"* ]]
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
  [ -z "$(ls -d "$WORK_DIR"/backup 2>/dev/null)" ]
}

@test "backup --all-databases backs up every discovered database into separate files" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --all-databases
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$WORK_DIR"/backup/mysql/h/* | tail -1)"
  [ -f "$backup_dir/db_one.sql.gz" ]
  [ -f "$backup_dir/db_two.sql.gz" ]
  zcat "$backup_dir/db_one.sql.gz" | grep -q "db=db_one"
  zcat "$backup_dir/db_two.sql.gz" | grep -q "db=db_two"
}

@test "list_all_databases excludes mysql_innodb_cluster_metadata from --all-databases" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" info \
    --host h --port 3306 --user u --password p --all-databases
  [ "$status" -eq 0 ]
  grep -- "SCHEMA_NAME NOT IN" "$STUB_LOG" | grep -q "mysql_innodb_cluster_metadata"
}

@test "backup gracefully degrades when mariadb-dump misdetects server as MariaDB 10.3+ (SHOW PACKAGE STATUS error)" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" MYSQLDUMP_ROUTINES_FAIL=1 "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]
  [[ "$output" == *"mydb"* ]]
  [[ "$output" == *"routine"* || "$output" == *"Routine"* || "$output" == *"stored procedure"* ]]
  [[ "$output" == *"omitted"* || "$output" == *"WARNING"* ]]

  backup_dir="$(ls -d "$WORK_DIR"/backup/mysql/h/* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]
  dump="$(zcat "$backup_dir/mydb.sql.gz")"
  [[ "$dump" == *"SCHEMA MARKER db=mydb"* ]]
  [[ "$dump" == *"DATA MARKER db=mydb"* ]]
  [[ "$dump" != *"partial, should be discarded"* ]]

  retry_line="$(grep -- "--no-data" "$STUB_LOG" | tail -1)"
  [[ "$retry_line" == *"--triggers"* ]]
  [[ "$retry_line" == *"--events"* ]]
  [[ "$retry_line" != *"--routines"* ]]

  # Two schema-pass attempts should have been made: the failing --routines
  # one and the successful retry without it.
  no_data_calls="$(grep -c -- "--no-data" "$STUB_LOG")"
  [ "$no_data_calls" -eq 2 ]
}

@test "backup does not retry without --routines when the schema dump fails for an unrelated reason" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" MYSQLDUMP_UNRELATED_FAIL=1 "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb
  [ "$status" -eq 1 ]
  [[ "$output" == *"Schema dump failed for database: mydb"* ]]
  [[ "$output" == *"Access denied"* ]]

  no_data_calls="$(grep -c -- "--no-data" "$STUB_LOG")"
  [ "$no_data_calls" -eq 1 ]
}

@test "backup without --dir uses backup/mysql/<host>/<timestamp>/ as the default path" {
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host mysql.internal --port 3306 --user u --password p --database mydb
  [ "$status" -eq 0 ]

  matches=("$WORK_DIR"/backup/mysql/mysql.internal/*/mydb.sql.gz)
  [ -f "${matches[0]}" ]
}

@test "backup without --dir uses the dbs.conf instance name (not the host) when a config instance is resolved" {
  cd "$WORK_DIR"
  cat > dbs.conf <<'EOF'
[prod]
type = mysql
host = mysql.internal
port = 3306
user = u
password = p
database = mydb
EOF
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup
  [ "$status" -eq 0 ]

  # Path should use the instance name "prod", not the host "mysql.internal".
  matches=("$WORK_DIR"/backup/mysql/prod/*/mydb.sql.gz)
  [ -f "${matches[0]}" ]
  [ ! -d "$WORK_DIR/backup/mysql/mysql.internal" ]
}

@test "sanitize_path_component replaces path-unsafe characters in a hostname with underscores" {
  # Sourcing the full script would execute main() with no args; DB_OPS_TEST
  # suppresses that so we can call the helper function directly.
  run env DB_OPS_TEST=1 bash -c '
    . "'"$SCRIPT"'"
    sanitize_path_component "evil/../host"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "evil_.._host" ]
}

@test "sanitize_path_component leaves legitimate hostnames with dots and dashes untouched" {
  run env DB_OPS_TEST=1 bash -c '
    . "'"$SCRIPT"'"
    sanitize_path_component "db-01.internal.example.com"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "db-01.internal.example.com" ]
}

@test "backup --dir behavior is unchanged (regression): still backup_<timestamp>/ under given base" {
  custom_base="$WORK_DIR/custom_backups2"
  mkdir -p "$custom_base"
  cd "$WORK_DIR"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$SCRIPT" backup \
    --host h --port 3306 --user u --password p --database mydb --dir "$custom_base"
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$custom_base"/backup_* | tail -1)"
  [ -f "$backup_dir/mydb.sql.gz" ]
  [[ "$backup_dir" == *"/backup_"* ]]
  [ -z "$(ls -d "$custom_base"/mysql 2>/dev/null)" ]
}
