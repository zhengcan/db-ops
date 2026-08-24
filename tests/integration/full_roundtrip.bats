#!/usr/bin/env bats

# NOTE: These three @test cases share one long-lived MySQL container and
# Alpine runner container for the whole file (see setup_file/teardown_file)
# instead of a fresh environment per test, to avoid repeatedly paying the
# container-startup cost. This means they have a real ordering dependency:
# test 1 leaves an extra "Gizmo" row in `products`, and test 3 reads its
# expected row count dynamically rather than hardcoding it for exactly this
# reason. Do not run these tests out of order or in parallel; add new tests
# to the end and re-derive any row-count expectations dynamically.

ALPINE_CONTAINER="my-ops-e2e-runner"

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait

  # Seed schema (docker-entrypoint-initdb.d bind mount is unreliable on
  # some hosts; pipe it in explicitly instead).
  # --default-character-set=utf8mb4 is required here too: init.sql contains
  # a 4-byte UTF-8 (emoji) literal, and without it the mysql client's own
  # default charset (not necessarily utf8mb4) could mangle it before it
  # even reaches my-ops.sh.
  docker compose exec -T mysql mysql --default-character-set=utf8mb4 -uroot -prootpass testdb < init.sql

  # Long-lived Alpine container to run my-ops.sh in, avoiding bind-mount
  # reliability issues: copy the script in once via `docker cp`.
  docker rm -f "$ALPINE_CONTAINER" >/dev/null 2>&1 || true
  docker create --name "$ALPINE_CONTAINER" --network db-ops-test-net \
    alpine:latest sh -c "sleep 3600" >/dev/null
  docker start "$ALPINE_CONTAINER" >/dev/null
  docker exec "$ALPINE_CONTAINER" mkdir -p /work
  docker cp "$BATS_TEST_DIRNAME/../../my-ops.sh" "$ALPINE_CONTAINER:/work/my-ops.sh"
  docker exec "$ALPINE_CONTAINER" sh -c "
    # Some networks (e.g. mainland China) cannot reach or TLS-verify
    # dl-cdn.alpinelinux.org reliably; mirrors.aliyun.com is a stable
    # mirror that works there. If your network reaches the official CDN
    # fine, this line is a harmless no-op to remove.
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
    apk add --no-cache mariadb-client mariadb-connector-c gzip gawk >/dev/null
    chmod +x /work/my-ops.sh
  "
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker rm -f "$ALPINE_CONTAINER" >/dev/null 2>&1 || true
  docker compose down -v
}

run_in_alpine() {
  docker exec -w /work "$ALPINE_CONTAINER" sh -c "$1"
}

query_testdb() {
  run_in_alpine "mysql --ssl --skip-ssl-verify-server-cert -h mysql -P 3306 -uroot -prootpass -N -B -e \"$1\" testdb 2>/dev/null"
}

latest_backup_dir() {
  # $1: optional subdirectory to look under (relative to /work), default /work
  # itself. When looking under the default location, backups now land in
  # backup/mysql/<host>/<timestamp>/ rather than a top-level backup_<ts>/
  # directory, so we locate it by finding the timestamp-named leaf directory.
  base="${1:-.}"
  if [ "$base" = "." ]; then
    run_in_alpine "find backup/mysql -mindepth 2 -maxdepth 2 -type d -name '2*' | tail -1"
  else
    run_in_alpine "ls -d ${base}/backup_* | tail -1"
  fi
}

@test "end to end: info, backup, restore reproduce all object types and data" {
  run run_in_alpine "rm -rf backup; ./my-ops.sh info --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(latest_backup_dir)"

  run query_testdb "DROP DATABASE testdb;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='testdb' AND TABLE_TYPE='BASE TABLE';"
  [ "$output" = "2" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='testdb' AND TABLE_TYPE='VIEW';"
  [ "$output" = "1" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='testdb';"
  [ "$output" = "1" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='testdb';"
  [ "$output" = "1" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='testdb';"
  [ "$output" = "1" ]

  run query_testdb "CALL add_product('Gizmo', 15.00);"
  [ "$status" -eq 0 ]
  run query_testdb "SELECT COUNT(*) FROM audit_log WHERE message LIKE '%Gizmo%';"
  [ "$output" = "1" ]

  # Regression: 4-byte UTF-8 (emoji) product name must round-trip exactly.
  # Prior to the --default-character-set=utf8mb4 fix in db_mysql()/
  # db_mysqldump(), this failed restore entirely with
  # "ERROR 1366: Incorrect string value", because restore_one_database()
  # imports data via a connection that never sees the dump's own
  # "SET NAMES utf8mb4" line (it lands in the schema half of the split).
  run query_testdb "SELECT HEX(name) FROM products WHERE name LIKE '%Roadwork%';"
  [ "$output" = "F09F9AA720526F6164776F726B20F09F8E89" ]

  run_in_alpine "rm -rf '${backup_dir}'"
}

@test "end to end: generated columns and blobs round-trip, --dir works, no __tmp columns remain" {
  run query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"
  before_output="$output"

  run run_in_alpine "rm -rf backup_* custom_backups; mkdir -p custom_backups; ./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb --dir custom_backups"
  [ "$status" -eq 0 ]
  backup_dir="$(latest_backup_dir custom_backups)"

  run query_testdb "DROP TABLE IF EXISTS products;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"
  [ "$status" -eq 0 ]
  [ "$output" = "$before_output" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='testdb' AND COLUMN_NAME LIKE '%__tmp';"
  [ "$output" = "0" ]

  run_in_alpine "rm -rf custom_backups"
}

@test "restore is idempotent when run twice against the same backup" {
  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$status" -eq 0 ]
  expected_count="$output"

  run run_in_alpine "rm -rf backup; ./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(latest_backup_dir)"

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$output" = "$expected_count" ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$output" = "$expected_count" ]

  run_in_alpine "rm -rf '${backup_dir}'"
}
