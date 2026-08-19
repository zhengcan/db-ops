#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs/query_aware"
  STUB_LOG="$(mktemp)"
  WORK_DIR="$(mktemp -d)"

  # A minimal backup archive: one table without generated columns
  # (audit_log) and one with (products, matching MYSQL_GENCOL_RESPONSE).
  cat > "$WORK_DIR/plain.sql" <<'EOF'
CREATE TABLE `audit_log` (`id` INT, `message` VARCHAR(255));
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'hello');
EOF
  gzip -c "$WORK_DIR/plain.sql" > "$WORK_DIR/plain_backup.sql.gz"

  cat > "$WORK_DIR/gencol.sql" <<'EOF'
CREATE TABLE `products` (`id` INT, `name` VARCHAR(100), `price` DECIMAL(10,2), `price_with_tax` DECIMAL(10,2), `name_upper` VARCHAR(100));
INSERT INTO `products` (`id`, `name`, `price`, `price_with_tax`, `name_upper`) VALUES (1,'Widget',9.99,10.99,'WIDGET');
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
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --database plaindb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --dir"* ]]
}

@test "restore requires an explicit --database" {
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}

@test "restore dies when the backup file for a database is missing" {
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database nosuchdb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup file not found"* ]]
}

@test "restore aborts without --force when the user declines confirmation" {
  run run_restore bash -c "echo n | \"$SCRIPT\" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database plaindb"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted by user"* ]]
}

@test "restore imports a database with no generated columns" {
  run run_restore env MYSQL_GENCOL_RESPONSE="" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database plaindb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: plaindb"* ]]
  grep -q "DROP DATABASE IF EXISTS \`plaindb\`" "$STUB_LOG"
  grep -q "CREATE DATABASE \`plaindb\`" "$STUB_LOG"
  ! grep -q "_tmp" "$STUB_LOG"
}

@test "restore stages generated columns through _tmp and cleans them up" {
  run run_restore env MYSQL_GENCOL_RESPONSE="$(printf 'products\tprice_with_tax\tdecimal(10,2)\nproducts\tname_upper\tvarchar(100)')" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database gencoldb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: gencoldb"* ]]
  grep -q "ADD COLUMN \`price_with_tax_tmp\` decimal(10,2)" "$STUB_LOG"
  grep -q "ADD COLUMN \`name_upper_tmp\` varchar(100)" "$STUB_LOG"
  grep -q "DROP COLUMN \`price_with_tax_tmp\`" "$STUB_LOG"
  grep -q "DROP COLUMN \`name_upper_tmp\`" "$STUB_LOG"
}

@test "restore processes every database in a comma-separated --database list" {
  run run_restore env MYSQL_GENCOL_RESPONSE="" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database plaindb,gencoldb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: plaindb"* ]]
  [[ "$output" == *"Restored database: gencoldb"* ]]
  grep -q "DROP DATABASE IF EXISTS \`plaindb\`" "$STUB_LOG"
  grep -q "CREATE DATABASE \`plaindb\`" "$STUB_LOG"
  grep -q "DROP DATABASE IF EXISTS \`gencoldb\`" "$STUB_LOG"
  grep -q "CREATE DATABASE \`gencoldb\`" "$STUB_LOG"
}
