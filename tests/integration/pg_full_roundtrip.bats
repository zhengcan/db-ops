#!/usr/bin/env bats

# NOTE: This file uses one long-lived PostgreSQL container and Alpine
# runner container for the whole file (see setup_file/teardown_file),
# mirroring full_roundtrip.bats's approach for my-ops.sh. See that file's
# header comment for why: bind mounts (docker-entrypoint-initdb.d, `docker
# run -v`) are unreliable under Rancher Desktop's virtiofs on this host, so
# seed data is piped in via `exec -T` and the script is copied in via
# `docker cp` into a long-lived runner container instead.
#
# Unlike the MySQL image, the postgres/pgvector image does NOT enable TLS
# by default (`SHOW ssl;` reports `off` on a freshly started container).
# There is no documented env var to turn it on for the official image, so
# setup_file generates a self-signed cert with openssl *inside* the running
# container (not via bind mount) and appends `ssl = on` plus the cert/key
# paths to postgresql.conf, then restarts the container so it takes effect.
# This was verified manually before writing this file (a fresh container
# reports `ssl = off`; after this procedure, `SHOW ssl;` reports `on` and
# `PGSSLMODE=require psql` succeeds against the self-signed cert).

COMPOSE_FILE="pg-docker-compose.yml"
ALPINE_CONTAINER="pg-ops-e2e-runner"

pg_compose() {
  docker compose -f "$COMPOSE_FILE" "$@"
}

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  pg_compose up -d --wait

  # Enable TLS: generate a self-signed cert inside the running container
  # (never via bind mount) and reconfigure postgresql.conf to use it.
  cat <<'SQLEOF' | pg_compose exec -T -u postgres postgres sh -c '
    cd "$PGDATA" &&
    openssl req -new -x509 -days 365 -nodes -text -out server.crt -keyout server.key -subj "/CN=postgres" 2>/dev/null &&
    chmod 600 server.key &&
    cat >> postgresql.conf
  '
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
SQLEOF

  pg_compose restart postgres
  # Wait for the restarted server to come back up and accept connections.
  for _ in $(seq 1 30); do
    pg_compose exec -T postgres pg_isready -U postgres >/dev/null 2>&1 && break
    sleep 1
  done

  # Seed schema (docker-entrypoint-initdb.d bind mount is unreliable on
  # some hosts; pipe it in explicitly instead).
  pg_compose exec -T postgres psql -U postgres testdb < pg-init.sql

  # Long-lived Alpine container to run pg-ops.sh in, avoiding bind-mount
  # reliability issues: copy the script in once via `docker cp`.
  docker rm -f "$ALPINE_CONTAINER" >/dev/null 2>&1 || true
  docker create --name "$ALPINE_CONTAINER" --network pg-ops-test-net \
    alpine:latest sh -c "sleep 3600" >/dev/null
  docker start "$ALPINE_CONTAINER" >/dev/null
  docker exec "$ALPINE_CONTAINER" mkdir -p /work
  docker cp "$BATS_TEST_DIRNAME/../../pg-ops.sh" "$ALPINE_CONTAINER:/work/pg-ops.sh"
  docker exec "$ALPINE_CONTAINER" sh -c "
    # Some networks (e.g. mainland China) cannot reach or TLS-verify
    # dl-cdn.alpinelinux.org reliably; mirrors.aliyun.com is a stable
    # mirror that works there. If your network reaches the official CDN
    # fine, this line is a harmless no-op to remove.
    sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
    apk add --no-cache postgresql-client gzip >/dev/null
    chmod +x /work/pg-ops.sh
  "
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker rm -f "$ALPINE_CONTAINER" >/dev/null 2>&1 || true
  pg_compose down -v
}

run_in_alpine() {
  docker exec -w /work "$ALPINE_CONTAINER" sh -c "$1"
}

query_testdb() {
  run_in_alpine "PGSSLMODE=require PGPASSWORD=rootpass psql -h postgres -p 5432 -U postgres -d testdb -tAc \"$1\" 2>/dev/null"
}

latest_backup_dir() {
  # $1: optional subdirectory to look under (relative to /work), default
  # backup/pg/<host>/<timestamp>/ (the default cmd_backup output location).
  base="${1:-.}"
  if [ "$base" = "." ]; then
    run_in_alpine "find backup/pg -mindepth 2 -maxdepth 2 -type d -name '2*' | tail -1"
  else
    run_in_alpine "ls -d ${base}/backup_* | tail -1"
  fi
}

@test "info reports connection OK over TLS (self-signed cert, PGSSLMODE=require) and correct object counts" {
  run run_in_alpine "./pg-ops.sh info --host postgres --port 5432 --user postgres --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK: postgres@postgres:5432"* ]]
  [[ "$output" == *"Database: testdb"* ]]
  [[ "$output" == *"Tables:               2"* ]]
  [[ "$output" == *"Views:                1"* ]]
  [[ "$output" == *"Functions:            2"* ]]
  [[ "$output" == *"Triggers:             1"* ]]
  [[ "$output" == *"Sequences:            3"* ]]
}

@test "end to end: backup then restore reproduces all object types, data, generated columns, and bytea exactly" {
  run query_testdb "SELECT id, name, price, price_with_tax, encode(thumbnail,'hex') FROM products ORDER BY id;"
  [ "$status" -eq 0 ]
  before_products="$output"

  run run_in_alpine "rm -rf backup; ./pg-ops.sh backup --host postgres --port 5432 --user postgres --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(latest_backup_dir)"
  [ -n "$backup_dir" ]

  run run_in_alpine "test -f '${backup_dir}/testdb.sql.gz' && echo yes"
  [[ "$output" == *"yes"* ]]

  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -c 'CREATE TABLE'"
  [ "$output" -ge 2 ]
  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -c 'GENERATED ALWAYS AS'"
  [ "$output" -ge 1 ]
  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -q 'CREATE VIEW expensive_products' && echo yes"
  [[ "$output" == *"yes"* ]]
  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -q 'CREATE.*FUNCTION' && echo yes"
  [[ "$output" == *"yes"* ]]
  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -q 'CREATE TRIGGER' && echo yes"
  [[ "$output" == *"yes"* ]]
  run run_in_alpine "zcat '${backup_dir}/testdb.sql.gz' | grep -q 'CREATE SEQUENCE' && echo yes"
  [[ "$output" == *"yes"* ]]

  # Break the database first, to prove the restore's DROP+CREATE cycle
  # actually rebuilds it (not just re-imports data into an existing db).
  run query_testdb "DROP TABLE products CASCADE;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./pg-ops.sh restore --host postgres --port 5432 --user postgres --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT id, name, price, price_with_tax, encode(thumbnail,'hex') FROM products ORDER BY id;"
  [ "$status" -eq 0 ]
  # Generated column (price_with_tax) and bytea (thumbnail, via hex
  # encoding) must both match exactly post-restore -- the generated column
  # value is recomputed by PostgreSQL itself (no __tmp staging column was
  # ever involved), and the bytea round-trips byte for byte.
  [ "$output" = "$before_products" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
  [ "$output" = "2" ]
  run query_testdb "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='VIEW';"
  [ "$output" = "1" ]
  run query_testdb "SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid WHERE n.nspname='public';"
  [ "$output" = "2" ]
  run query_testdb "SELECT COUNT(DISTINCT trigger_name) FROM information_schema.triggers WHERE trigger_schema='public';"
  [ "$output" = "1" ]
  run query_testdb "SELECT COUNT(*) FROM pg_sequences WHERE schemaname='public';"
  [ "$output" = "3" ]

  # The function and trigger must actually work post-restore (not just
  # exist as dead DDL): calling add_product() should both insert into
  # products (firing the AFTER INSERT trigger) and the trigger should in
  # turn insert into audit_log.
  run query_testdb "SELECT add_product('Gizmo', 15.00);"
  [ "$status" -eq 0 ]
  run query_testdb "SELECT COUNT(*) FROM audit_log WHERE message LIKE '%Gizmo%';"
  [ "$output" = "1" ]

  run_in_alpine "rm -rf '${backup_dir}'"
}

@test "no __tmp staging columns are ever created during restore (unlike my-ops.sh's generated-column handling)" {
  run query_testdb "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='public' AND column_name LIKE '%\\_\\_tmp';"
  [ "$output" = "0" ]
}

@test "restore is idempotent when run twice against the same backup, and --dir works with a custom base path" {
  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$status" -eq 0 ]
  expected_count="$output"

  run run_in_alpine "rm -rf custom_backups; mkdir -p custom_backups; ./pg-ops.sh backup --host postgres --port 5432 --user postgres --password rootpass --database testdb --dir custom_backups"
  [ "$status" -eq 0 ]
  backup_dir="$(latest_backup_dir custom_backups)"
  [ -n "$backup_dir" ]

  run run_in_alpine "./pg-ops.sh restore --host postgres --port 5432 --user postgres --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]
  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$output" = "$expected_count" ]

  run run_in_alpine "./pg-ops.sh restore --host postgres --port 5432 --user postgres --password rootpass --dir '${backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]
  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$output" = "$expected_count" ]

  run_in_alpine "rm -rf custom_backups"
}

@test "dbs.conf: pg-ops.sh works via a shared config instance (type=pg), and rejects a type=mysql instance by name" {
  run_in_alpine "cat > dbs.conf <<'EOF'
[pgprod]
type = pg
host = postgres
port = 5432
user = postgres
password = rootpass
database = testdb

[mysqlprod]
type = mysql
host = somemysqlhost
EOF"

  run run_in_alpine "./pg-ops.sh info --instance pgprod"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK: postgres@postgres:5432"* ]]
  [[ "$output" == *"Database: testdb"* ]]

  run run_in_alpine "./pg-ops.sh info --instance mysqlprod"
  [ "$status" -eq 1 ]
  [[ "$output" == *"type=mysql"* ]]
  [[ "$output" == *"only supports pg instances"* ]]

  run_in_alpine "rm -f dbs.conf"
}
