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

  # Two different tables that both have a generated column with the SAME
  # name ("total"), to verify generated-column handling is scoped per
  # table and not globally by column name.
  cat > "$WORK_DIR/multi_table_gencol.sql" <<'EOF'
CREATE TABLE `products` (`id` INT, `qty` INT, `unit_price` DECIMAL(10,2), `total` DECIMAL(10,2));
CREATE TABLE `inventory` (`id` INT, `count` INT, `weight` DECIMAL(10,2), `total` DECIMAL(10,2));
INSERT INTO `products` (`id`, `qty`, `unit_price`, `total`) VALUES (1,2,5.00,10.00);
INSERT INTO `inventory` (`id`, `count`, `weight`, `total`) VALUES (1,3,4.00,12.00);
EOF
  gzip -c "$WORK_DIR/multi_table_gencol.sql" > "$WORK_DIR/multi_table_gencol_backup.sql.gz"

  mkdir -p "$WORK_DIR/backup_20260101_000000"
  cp "$WORK_DIR/plain_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/plaindb.sql.gz"
  cp "$WORK_DIR/gencol_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/gencoldb.sql.gz"
  cp "$WORK_DIR/multi_table_gencol_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/multitabledb.sql.gz"
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

@test "restore rejects --all-databases" {
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --all-databases --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"restore does not support --all-databases"* ]]
}

@test "restore rejects combining --database and --all-databases with the more general error" {
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database plaindb --all-databases --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot combine --database and --all-databases"* ]]
}

@test "restore dies when the backup file for a database is missing" {
  run run_restore "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database nosuchdb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup file not found"* ]]
}

@test "restore aborts without --force when the user declines confirmation" {
  run run_restore env DB_OPS_TEST_CONFIRM_STDIN=1 bash -c "echo n | \"$SCRIPT\" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database plaindb"
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
  ! grep -q "__tmp" "$STUB_LOG"
}

@test "restore stages generated columns through __tmp and cleans them up" {
  run run_restore env MYSQL_GENCOL_RESPONSE="$(printf 'products\tprice_with_tax\tdecimal(10,2)\nproducts\tname_upper\tvarchar(100)')" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database gencoldb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: gencoldb"* ]]
  grep -q "ADD COLUMN \`price_with_tax__tmp\` decimal(10,2)" "$STUB_LOG"
  grep -q "ADD COLUMN \`name_upper__tmp\` varchar(100)" "$STUB_LOG"
  grep -q "DROP COLUMN \`price_with_tax__tmp\`" "$STUB_LOG"
  grep -q "DROP COLUMN \`name_upper__tmp\`" "$STUB_LOG"
}

@test "restore handles two different tables that both have a generated column with the same name" {
  # `products.total` and `inventory.total` are both generated columns
  # sharing the identical column name. Staging/redirection must be scoped
  # per table, not globally by column name, so both get their own
  # independent total__tmp handling without colliding.
  run run_restore env MYSQL_GENCOL_RESPONSE="$(printf 'products\ttotal\tdecimal(10,2)\ninventory\ttotal\tdecimal(10,2)')" \
    STUB_STDIN_CAPTURE="$WORK_DIR/stdin_capture.sql" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database multitabledb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: multitabledb"* ]]

  # Both tables got their own ADD/DROP COLUMN calls for total__tmp.
  grep -q "ALTER TABLE \`products\` ADD COLUMN \`total__tmp\` decimal(10,2)" "$STUB_LOG"
  grep -q "ALTER TABLE \`inventory\` ADD COLUMN \`total__tmp\` decimal(10,2)" "$STUB_LOG"
  grep -q "ALTER TABLE \`products\` DROP COLUMN \`total__tmp\`" "$STUB_LOG"
  grep -q "ALTER TABLE \`inventory\` DROP COLUMN \`total__tmp\`" "$STUB_LOG"

  # The actual data import redirected each table's `total` column to
  # total__tmp independently -- neither table's INSERT should reference
  # the *other* table's data by name collision, and both INSERT column
  # lists must show total__tmp (not the untouched `total`).
  capture="$WORK_DIR/stdin_capture.sql"
  [ -f "$capture" ]
  grep -q '`products` (`id`, `qty`, `unit_price`, `total__tmp`) VALUES (1,2,5.00,10.00)' "$capture"
  grep -q '`inventory` (`id`, `count`, `weight`, `total__tmp`) VALUES (1,3,4.00,12.00)' "$capture"
}

@test "restore strips mysqldump SET @OLD_ session bookkeeping so cross-connection restore doesn't see NULL vars" {
  # Mimics real mysqldump output structure: first table has NO data rows
  # (its SAVE @OLD_AUTOCOMMIT happens before the first literal "INSERT INTO"
  # line anywhere in the file, so the naive awk splitter would misclassify
  # it into schema_sql, while the matching RESTORE line for the *next*
  # table's wrapper ends up in data_sql -- a completely separate mysql
  # connection that never saw the SET @OLD_AUTOCOMMIT assignment).
  cat > "$WORK_DIR/realistic.sql" <<'EOF'
CREATE TABLE `empty_table` (`id` INT);
SET @OLD_AUTOCOMMIT=@@AUTOCOMMIT, @@AUTOCOMMIT=0;
LOCK TABLES `empty_table` WRITE;
UNLOCK TABLES;
SET AUTOCOMMIT=@OLD_AUTOCOMMIT;
CREATE TABLE `nonempty_table` (`id` INT, `name` VARCHAR(50));
SET @OLD_AUTOCOMMIT=@@AUTOCOMMIT, @@AUTOCOMMIT=0;
LOCK TABLES `nonempty_table` WRITE;
INSERT INTO `nonempty_table` (`id`, `name`) VALUES (1,'hi');
UNLOCK TABLES;
SET AUTOCOMMIT=@OLD_AUTOCOMMIT;
EOF
  gzip -c "$WORK_DIR/realistic.sql" > "$WORK_DIR/realistic_backup.sql.gz"
  mkdir -p "$WORK_DIR/backup_20260101_000000"
  cp "$WORK_DIR/realistic_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/realisticdb.sql.gz"

  STDIN_CAPTURE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_STDIN_CAPTURE="$STDIN_CAPTURE" \
    MYSQL_GENCOL_RESPONSE="" \
    bash -c "cd '$WORK_DIR' && '$SCRIPT' restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database realisticdb --force"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: realisticdb"* ]]

  # (a) All SAVE/RESTORE bookkeeping lines must be gone from what was
  # actually piped into mysql (both the schema and data imports).
  ! grep -Eq '(SET @OLD_[A-Za-z_]+=|SET [A-Za-z_]+=@OLD_[A-Za-z_]+)' "$STDIN_CAPTURE"

  # (b) Legitimate content must survive: table definitions and the real
  # INSERT statement must still be present somewhere in the captured
  # stdin streams.
  grep -q "CREATE TABLE \`empty_table\`" "$STDIN_CAPTURE"
  grep -q "CREATE TABLE \`nonempty_table\`" "$STDIN_CAPTURE"
  grep -q "INSERT INTO \`nonempty_table\`" "$STDIN_CAPTURE"

  rm -f "$STDIN_CAPTURE"
}

@test "restore does not strip legitimate @saved_cs_client-style SET statements" {
  cat > "$WORK_DIR/saved_cs.sql" <<'EOF'
CREATE TABLE `t1` (`id` INT);
/*!50003 SET @saved_cs_client      = @@character_set_client */ ;
/*!50003 SET character_set_client = utf8mb4 */ ;
CREATE VIEW `v1` AS SELECT id FROM t1;
/*!50003 SET character_set_client = @saved_cs_client */ ;
INSERT INTO `t1` (`id`) VALUES (1);
EOF
  gzip -c "$WORK_DIR/saved_cs.sql" > "$WORK_DIR/saved_cs_backup.sql.gz"
  mkdir -p "$WORK_DIR/backup_20260101_000000"
  cp "$WORK_DIR/saved_cs_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/savedcsdb.sql.gz"

  STDIN_CAPTURE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_STDIN_CAPTURE="$STDIN_CAPTURE" \
    MYSQL_GENCOL_RESPONSE="" \
    bash -c "cd '$WORK_DIR' && '$SCRIPT' restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database savedcsdb --force"
  [ "$status" -eq 0 ]

  grep -q "@saved_cs_client" "$STDIN_CAPTURE"
  grep -q "CREATE VIEW \`v1\`" "$STDIN_CAPTURE"
  grep -q "INSERT INTO \`t1\`" "$STDIN_CAPTURE"

  rm -f "$STDIN_CAPTURE"
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

@test "restore explicitly sets FOREIGN_KEY_CHECKS/UNIQUE_CHECKS/AUTOCOMMIT itself rather than relying on mysqldump's @OLD_ bookkeeping" {
  # Realistic mysqldump global header: these two compound lines both save
  # the previous value into an @OLD_ variable AND flip the session setting
  # to make dependency-order-agnostic restore possible. They must still be
  # stripped from the piped SQL (same as before), but the underlying
  # session settings must now be established by our own explicit SET
  # statements instead of depending on the (cross-connection-broken)
  # mysqldump bookkeeping.
  cat > "$WORK_DIR/fk.sql" <<'EOF'
/*!40014 SET @OLD_FOREIGN_KEY_CHECKS=@@FOREIGN_KEY_CHECKS, FOREIGN_KEY_CHECKS=0 */;
/*!40014 SET @OLD_UNIQUE_CHECKS=@@UNIQUE_CHECKS, UNIQUE_CHECKS=0 */;
CREATE TABLE `categories` (`id` INT PRIMARY KEY);
CREATE TABLE `products_fk` (`id` INT PRIMARY KEY, `category_id` INT, FOREIGN KEY (`category_id`) REFERENCES `categories`(`id`));
INSERT INTO `categories` (`id`) VALUES (1);
INSERT INTO `products_fk` (`id`, `category_id`) VALUES (1,1);
EOF
  gzip -c "$WORK_DIR/fk.sql" > "$WORK_DIR/fk_backup.sql.gz"
  mkdir -p "$WORK_DIR/backup_20260101_000000"
  cp "$WORK_DIR/fk_backup.sql.gz" "$WORK_DIR/backup_20260101_000000/fkdb.sql.gz"

  STDIN_CAPTURE="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" STUB_STDIN_CAPTURE="$STDIN_CAPTURE" \
    MYSQL_GENCOL_RESPONSE="" \
    bash -c "cd '$WORK_DIR' && '$SCRIPT' restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database fkdb --force"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: fkdb"* ]]

  # The mysqldump @OLD_ bookkeeping lines must still be stripped.
  ! grep -Eq '(SET @OLD_[A-Za-z_]+=|SET [A-Za-z_]+=@OLD_[A-Za-z_]+)' "$STDIN_CAPTURE"

  # But the actual content piped into mysql must contain our own explicit
  # FOREIGN_KEY_CHECKS=0 (and friends) setting, proving the script no
  # longer relies on mysqldump's cross-connection-broken bookkeeping.
  grep -q "SET FOREIGN_KEY_CHECKS=0" "$STDIN_CAPTURE"
  grep -q "SET UNIQUE_CHECKS=0" "$STDIN_CAPTURE"
  grep -q "SET AUTOCOMMIT=0" "$STDIN_CAPTURE"

  # Legitimate content must survive.
  grep -q "CREATE TABLE \`categories\`" "$STDIN_CAPTURE"
  grep -q "CREATE TABLE \`products_fk\`" "$STDIN_CAPTURE"
  grep -q "INSERT INTO \`products_fk\`" "$STDIN_CAPTURE"

  rm -f "$STDIN_CAPTURE"
}
