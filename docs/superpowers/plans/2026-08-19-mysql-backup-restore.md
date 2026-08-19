# MySQL Backup/Restore Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single POSIX-shell tool (`db-ops.sh`) that runs on bare Alpine (self-installing its dependencies via `apk`) and can back up and restore all user tables, views, routines, triggers, and events of a MySQL database over a TLS connection that trusts self-signed certificates, correctly round-tripping generated (virtual/stored) columns and binary (BLOB) data.

**Architecture:** A dispatcher script (`db-ops.sh`) sources small library files under `lib/` for shared config/connection helpers (`common.sh`) and per-subcommand logic (`info.sh`, `backup.sh`, `restore.sh`). Generated-column handling is isolated in a `gawk` filter script (`lib/gencol_filter.awk`) that rewrites `INSERT` column lists at restore time, decoupled from value parsing.

**Tech Stack:** POSIX `sh`, `mariadb-client` (`mysql`/`mysqldump`/`mysqladmin`), `mariadb-connector-c`, `gzip`, `gawk` — all installed via `apk` at runtime. Development/testing tooling: `bats-core` (unit tests) and Docker (integration environment with `mysql:8.0`, which auto-generates a self-signed TLS cert).

## Global Constraints

- Target runtime is bare Alpine; every non-busybox dependency (`mariadb-client`, `mariadb-connector-c`, `gzip`, `gawk`) must be auto-installed via `apk add --no-cache` if missing — never assume pre-installed.
- All MySQL client connections must include `--ssl-mode=REQUIRED --ssl-verify-server-cert=0` (encrypt, do not validate self-signed certs).
- Passwords must never appear in process argument lists — always pass via a temporary `--defaults-extra-file` (`[client]` section), deleted on exit via `trap`.
- Backup must cover: all user tables (DDL+DML), views, stored procedures/functions, triggers, and events.
- BLOB/binary columns must be exported with `--hex-blob`.
- Generated (virtual/stored) columns must never have their original column touched (no `DROP`/`ALTER` on the generated column itself) — only an additive `<col>_tmp` staging column is used, so indexes/constraints on the table are unaffected.
- Backup output: one directory per run, `backup_<YYYYMMDD_HHMMSS>/`, one file per database, `<db>.sql.gz`.
- Restore requires an explicit `--database <db1,db2>` list — restoring "everything in a directory" implicitly is not supported.
- Restore is destructive per database (`DROP DATABASE IF EXISTS` + `CREATE DATABASE`) and requires interactive confirmation unless `--force` is passed.

---

### Task 1: Config parsing and CLI scaffolding

**Files:**
- Create: `db-ops.sh`
- Create: `lib/common.sh`
- Test: `tests/unit/common.bats`

**Interfaces:**
- Produces (used by all later tasks):
  - Variables set after `parse_common_args "$@"` + `load_config`: `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_DATABASE` (raw comma string), `DB_ALL_DATABASES` (0/1), `FORCE` (0/1), `BACKUP_DIR`, `CONFIG_FILE`
  - `die "message"` — prints to stderr, exits 1
  - `split_csv "a, b ,c"` — prints trimmed newline-separated items
  - `confirm "prompt"` — returns 0 if `FORCE=1` or user answers y/Y/yes, else 1
  - `$LIB_DIR` — absolute path to `lib/`, set as a global in `db-ops.sh`

- [ ] **Step 1: Write the failing bats test**

Create `tests/unit/common.bats`:

```bash
#!/usr/bin/env bats

setup() {
  LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
  # shellcheck disable=SC1090
  . "$LIB_DIR/common.sh"
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
  FORCE=0
  run bash -c '. "'"$LIB_DIR"'/common.sh"; FORCE=0; echo y | confirm "Proceed?"'
  [ "$status" -eq 0 ]
}

@test "confirm returns failure when user answers n" {
  FORCE=0
  run bash -c '. "'"$LIB_DIR"'/common.sh"; FORCE=0; echo n | confirm "Proceed?"'
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/common.bats`
Expected: FAIL — `lib/common.sh` does not exist yet.

- [ ] **Step 3: Implement `lib/common.sh`**

Create `lib/common.sh`:

```sh
#!/bin/sh
# common.sh - shared config parsing, dependency management, and DB
# connection helpers for db-ops.sh

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-3306}"
DB_USER="${DB_USER:-root}"
DB_PASSWORD="${DB_PASSWORD:-}"
DB_DATABASE="${DB_DATABASE:-}"
DB_ALL_DATABASES=0
FORCE=0
BACKUP_DIR=""
CONFIG_FILE=""

_TMP_DEFAULTS_FILE=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_common_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config) CONFIG_FILE="$2"; shift 2 ;;
      --host) DB_HOST="$2"; shift 2 ;;
      --port) DB_PORT="$2"; shift 2 ;;
      --user) DB_USER="$2"; shift 2 ;;
      --password) DB_PASSWORD="$2"; shift 2 ;;
      --database) DB_DATABASE="$2"; shift 2 ;;
      --all-databases) DB_ALL_DATABASES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dir) BACKUP_DIR="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

load_config() {
  if [ -n "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

split_csv() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

confirm() {
  msg="$1"
  if [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  printf '%s [y/N] ' "$msg"
  read -r reply
  case "$reply" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/common.bats`
Expected: all `parse_common_args`/`split_csv`/`load_config`/`confirm` tests PASS. (The dependency/connection tests referenced in Task 2 are not in this file yet.)

- [ ] **Step 5: Create the dispatcher script**

Create `db-ops.sh`:

```sh
#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck disable=SC1090
. "$LIB_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: db-ops.sh <command> [options]

Commands:
  info      Show connection status and object overview
  backup    Backup one or more databases
  restore   Restore one or more databases from a backup directory

Common options:
  --config <file>       KEY=VALUE config file
  --host <host>         MySQL host (default 127.0.0.1)
  --port <port>         MySQL port (default 3306)
  --user <user>         MySQL user (default root)
  --password <password> MySQL password (prefer DB_PASSWORD env var)

backup options:
  --database <db1,db2>  Comma-separated list of databases to back up
  --all-databases        Back up all non-system databases

restore options:
  --dir <backup_dir>     Backup directory produced by 'backup'
  --database <db1,db2>   Comma-separated list of databases to restore
  --force                Skip confirmation prompt
EOF
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 1
  fi

  cmd="$1"
  shift

  parse_common_args "$@"
  load_config

  case "$cmd" in
    info)
      # shellcheck disable=SC1090
      . "$LIB_DIR/info.sh"
      cmd_info
      ;;
    backup)
      # shellcheck disable=SC1090
      . "$LIB_DIR/backup.sh"
      cmd_backup
      ;;
    restore)
      # shellcheck disable=SC1090
      . "$LIB_DIR/restore.sh"
      cmd_restore
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
```

Run: `chmod +x db-ops.sh`

- [ ] **Step 6: Commit**

```bash
git add db-ops.sh lib/common.sh tests/unit/common.bats
git commit -m "feat: add CLI scaffolding and config parsing"
```

---

### Task 2: Dependency installation and secure connection helpers

**Files:**
- Modify: `lib/common.sh`
- Create: `tests/unit/connection.bats`
- Create: `tests/unit/stubs/mysql`
- Create: `tests/unit/stubs/mysqladmin`
- Create: `tests/unit/stubs/mysqldump`
- Create: `tests/unit/stubs/apk`

**Interfaces:**
- Consumes: `die`, `$DB_HOST`, `$DB_PORT`, `$DB_USER`, `$DB_PASSWORD` from Task 1
- Produces (used by Task 3+):
  - `ensure_dependencies` — installs `mariadb-client mariadb-connector-c gzip gawk` via `apk` if any of `mysql mysqldump mysqladmin gzip gawk` is missing; dies if still missing after install
  - `make_defaults_file` — creates `$_TMP_DEFAULTS_FILE` (mode 600) containing `[client]\npassword=$DB_PASSWORD`
  - `db_mysql [args...]`, `db_mysqldump [args...]`, `db_mysqladmin [args...]` — wrappers that inject `--defaults-extra-file`, `--host`, `--port`, `--user`, `--ssl-mode=REQUIRED`, `--ssl-verify-server-cert=0`
  - `check_connection` — dies if `db_mysqladmin ping` fails
  - `cleanup_common` (registered via `trap ... EXIT INT TERM`) — removes `$_TMP_DEFAULTS_FILE`

- [ ] **Step 1: Write stub binaries for unit testing**

Create `tests/unit/stubs/mysql`:
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQL_EXIT_CODE:-0}"
```

Create `tests/unit/stubs/mysqladmin`:
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQLADMIN_EXIT_CODE:-0}"
```

Create `tests/unit/stubs/mysqldump`:
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQLDUMP_EXIT_CODE:-0}"
```

Create `tests/unit/stubs/apk`:
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
if [ "$1" = "add" ]; then
  dir="$(dirname "$0")"
  for bin in mysql mysqldump mysqladmin gzip gawk; do
    cat > "$dir/$bin" <<'INNER'
#!/bin/sh
exit 0
INNER
    chmod +x "$dir/$bin"
  done
fi
exit 0
```

Run: `chmod +x tests/unit/stubs/mysql tests/unit/stubs/mysqladmin tests/unit/stubs/mysqldump tests/unit/stubs/apk`

- [ ] **Step 2: Write the failing bats test**

Create `tests/unit/connection.bats`:

```bash
#!/usr/bin/env bats

setup() {
  LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$(mktemp)"
  export STUB_LOG
  PATH="$STUB_DIR:$PATH"
  export PATH
  # shellcheck disable=SC1090
  . "$LIB_DIR/common.sh"
  DB_HOST="testhost"
  DB_PORT="3306"
  DB_USER="testuser"
  DB_PASSWORD="testpass"
}

teardown() {
  rm -f "$STUB_LOG"
}

@test "db_mysqladmin invokes mysqladmin with required SSL flags and connection args" {
  run db_mysqladmin ping
  [ "$status" -eq 0 ]
  grep -q -- "--ssl-mode=REQUIRED" "$STUB_LOG"
  grep -q -- "--ssl-verify-server-cert=0" "$STUB_LOG"
  grep -q -- "--host=testhost" "$STUB_LOG"
  grep -q -- "--port=3306" "$STUB_LOG"
  grep -q -- "--user=testuser" "$STUB_LOG"
  grep -q -- "ping" "$STUB_LOG"
}

@test "make_defaults_file writes password into a client section file with mode 600" {
  make_defaults_file
  [ -f "$_TMP_DEFAULTS_FILE" ]
  grep -q "^password=testpass$" "$_TMP_DEFAULTS_FILE"
  perms="$(stat -f '%Lp' "$_TMP_DEFAULTS_FILE" 2>/dev/null || stat -c '%a' "$_TMP_DEFAULTS_FILE")"
  [ "$perms" = "600" ]
}

@test "check_connection succeeds when mysqladmin ping stub returns 0" {
  run check_connection
  [ "$status" -eq 0 ]
}

@test "check_connection fails when mysqladmin ping stub returns error" {
  MYSQLADMIN_EXIT_CODE=1
  export MYSQLADMIN_EXIT_CODE
  run check_connection
  [ "$status" -eq 1 ]
}

@test "ensure_dependencies is a no-op when all binaries are already present" {
  run ensure_dependencies
  [ "$status" -eq 0 ]
  ! grep -q "apk add" "$STUB_LOG"
}

@test "ensure_dependencies installs missing packages via apk" {
  fake_bin="$(mktemp -d)"
  cp "$STUB_DIR/apk" "$fake_bin/apk"
  chmod +x "$fake_bin/apk"

  run env PATH="$fake_bin" STUB_LOG="$STUB_LOG" sh -c ". '$LIB_DIR/common.sh'; ensure_dependencies"

  [ "$status" -eq 0 ]
  grep -q "apk add --no-cache mariadb-client mariadb-connector-c gzip gawk" "$STUB_LOG"
  [ -x "$fake_bin/mysql" ]
  rm -rf "$fake_bin"
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bats tests/unit/connection.bats`
Expected: FAIL — `ensure_dependencies`, `make_defaults_file`, `db_mysql`, `db_mysqladmin`, `check_connection` not defined.

- [ ] **Step 4: Implement the connection helpers**

Append to `lib/common.sh`:

```sh

cleanup_common() {
  if [ -n "$_TMP_DEFAULTS_FILE" ] && [ -f "$_TMP_DEFAULTS_FILE" ]; then
    rm -f "$_TMP_DEFAULTS_FILE"
  fi
}
trap cleanup_common EXIT INT TERM

ensure_dependencies() {
  need_install=0
  for bin in mysql mysqldump mysqladmin gzip gawk; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      need_install=1
    fi
  done

  if [ "$need_install" -eq 1 ]; then
    command -v apk >/dev/null 2>&1 || die "apk not found; cannot auto-install dependencies"
    apk add --no-cache mariadb-client mariadb-connector-c gzip gawk >&2 \
      || die "Failed to install dependencies via apk"
  fi

  for bin in mysql mysqldump mysqladmin gzip gawk; do
    command -v "$bin" >/dev/null 2>&1 || die "Required command still missing after install: $bin"
  done
}

# Writes a temporary my.cnf-style defaults file containing the password,
# so it never appears in the process argument list. Sets _TMP_DEFAULTS_FILE.
make_defaults_file() {
  _TMP_DEFAULTS_FILE="$(mktemp)"
  chmod 600 "$_TMP_DEFAULTS_FILE"
  printf '[client]\npassword=%s\n' "$DB_PASSWORD" > "$_TMP_DEFAULTS_FILE"
}

_conn_flags() {
  printf '%s\n' \
    "--defaults-extra-file=${_TMP_DEFAULTS_FILE}" \
    "--host=${DB_HOST}" \
    "--port=${DB_PORT}" \
    "--user=${DB_USER}" \
    "--ssl-mode=REQUIRED" \
    "--ssl-verify-server-cert=0"
}

db_mysql() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  mysql $(_conn_flags) "$@"
}

db_mysqldump() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  mysqldump $(_conn_flags) "$@"
}

db_mysqladmin() {
  [ -n "$_TMP_DEFAULTS_FILE" ] || make_defaults_file
  mysqladmin $(_conn_flags) "$@"
}

check_connection() {
  db_mysqladmin ping >/dev/null 2>&1 || die "Cannot connect to MySQL at ${DB_HOST}:${DB_PORT}"
}

list_all_databases() {
  db_mysql -N -B -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys');"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bats tests/unit/connection.bats`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/common.sh tests/unit/connection.bats tests/unit/stubs
git commit -m "feat: add dependency install and secure connection helpers"
```

---

### Task 3: Integration test environment (Docker + self-signed TLS MySQL)

**Files:**
- Create: `tests/integration/docker-compose.yml`
- Create: `tests/integration/init.sql`

**Interfaces:**
- Produces: a running `mysql:8.0` container (service name `mysql`, network `db-ops-test-net`, database `testdb`, root password `rootpass`) auto-generating a self-signed TLS certificate on first start, seeded with a schema covering: a table with a `VIRTUAL` generated column, a table with a `STORED` generated column, a `BLOB` column, a view, a stored procedure, a trigger, and an event. Later tasks connect to it via `docker run --network db-ops-test-net ... alpine:3.19` to prove the tool runs on bare Alpine.

- [ ] **Step 1: Write the seed schema**

Create `tests/integration/init.sql`:

```sql
CREATE TABLE products (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  price DECIMAL(10,2) NOT NULL,
  price_with_tax DECIMAL(10,2) AS (price * 1.1) VIRTUAL,
  name_upper VARCHAR(100) AS (UPPER(name)) STORED,
  thumbnail BLOB
);

INSERT INTO products (name, price, thumbnail) VALUES
  ('Widget', 9.99, UNHEX('89504E470D0A1A0A')),
  ('Gadget', 19.99, UNHEX('FFD8FFE000104A46')),
  ('Doohickey', 5.49, NULL);

CREATE VIEW expensive_products AS
  SELECT id, name, price FROM products WHERE price > 10;

CREATE TABLE audit_log (
  id INT AUTO_INCREMENT PRIMARY KEY,
  message VARCHAR(255),
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

DELIMITER $$
CREATE PROCEDURE add_product(IN p_name VARCHAR(100), IN p_price DECIMAL(10,2))
BEGIN
  INSERT INTO products (name, price) VALUES (p_name, p_price);
END$$

CREATE TRIGGER products_after_insert
AFTER INSERT ON products
FOR EACH ROW
BEGIN
  INSERT INTO audit_log (message) VALUES (CONCAT('Inserted product: ', NEW.name));
END$$
DELIMITER ;

SET GLOBAL event_scheduler = ON;

CREATE EVENT cleanup_audit_log
ON SCHEDULE EVERY 1 DAY
DO
  DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 30 DAY;
```

- [ ] **Step 2: Write the compose file**

Create `tests/integration/docker-compose.yml`:

```yaml
networks:
  default:
    name: db-ops-test-net

services:
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: testdb
    ports:
      - "3307:3306"
    volumes:
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-prootpass"]
      interval: 5s
      timeout: 5s
      retries: 20
```

- [ ] **Step 3: Bring the environment up and verify it manually**

Run:
```bash
cd tests/integration
docker compose up -d --wait
```
Expected: command exits 0, `docker compose ps` shows `mysql` as `healthy`.

- [ ] **Step 4: Verify self-signed TLS and seeded schema from a bare Alpine container**

Run:
```bash
docker run --rm --network db-ops-test-net alpine:3.19 sh -c "
  apk add --no-cache mariadb-client >/dev/null &&
  mysql --ssl-mode=REQUIRED --ssl-verify-server-cert=0 \
    -h mysql -P 3306 -uroot -prootpass testdb \
    -e 'SHOW TABLES; SELECT COUNT(*) FROM products;'
"
```
Expected: prints table list (`audit_log`, `products`) and a row count of `3`, with no TLS certificate errors.

- [ ] **Step 5: Commit**

```bash
git add tests/integration/docker-compose.yml tests/integration/init.sql
git commit -m "test: add dockerized MySQL integration environment with self-signed TLS"
```

---

### Task 4: `info` subcommand

**Files:**
- Create: `lib/info.sh`
- Create: `tests/integration/info.bats`

**Interfaces:**
- Consumes: `ensure_dependencies`, `check_connection`, `list_all_databases`, `split_csv`, `die`, `db_mysql` from Tasks 1–2; `$DB_DATABASE`, `$DB_ALL_DATABASES` from parsed args
- Produces: `cmd_info` — entry point called by `db-ops.sh info`

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration/info.bats`:

```bash
#!/usr/bin/env bats

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose down -v
}

run_in_alpine() {
  docker run --rm --network db-ops-test-net \
    -v "$BATS_TEST_DIRNAME/../..":/work -w /work \
    alpine:3.19 sh -c "$1"
}

@test "info reports successful connection and object counts for testdb" {
  run run_in_alpine "./db-ops.sh info --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Connection OK"* ]]
  [[ "$output" == *"Database: testdb"* ]]
  [[ "$output" == *"Tables:"* ]]
  [[ "$output" == *"Views:"* ]]
  [[ "$output" == *"Routines"* ]]
  [[ "$output" == *"Triggers:"* ]]
  [[ "$output" == *"Events:"* ]]
}

@test "info fails with a clear error when no database is specified" {
  run run_in_alpine "./db-ops.sh info --host mysql --port 3306 --user root --password rootpass"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/info.bats`
Expected: FAIL — `lib/info.sh` does not exist, `db-ops.sh info` errors with "Unknown command" style failure or missing file.

- [ ] **Step 3: Implement `lib/info.sh`**

Create `lib/info.sh`:

```sh
#!/bin/sh
# info.sh - db-ops info subcommand

cmd_info() {
  ensure_dependencies
  check_connection
  echo "Connection OK: ${DB_USER}@${DB_HOST}:${DB_PORT}"

  if [ "$DB_ALL_DATABASES" -eq 1 ]; then
    databases="$(list_all_databases)"
  elif [ -n "$DB_DATABASE" ]; then
    databases="$(split_csv "$DB_DATABASE")"
  else
    die "Specify --database <db1,db2> or --all-databases"
  fi

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    echo ""
    echo "Database: $db"
    tables=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';")
    views=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='VIEW';")
    routines=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='${db}';")
    triggers=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='${db}';")
    events=$(db_mysql -N -B -e "SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='${db}';")
    echo "  Tables:               $tables"
    echo "  Views:                $views"
    echo "  Routines (proc/func): $routines"
    echo "  Triggers:             $triggers"
    echo "  Events:               $events"
  done
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/info.bats`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/info.sh tests/integration/info.bats
git commit -m "feat: add info subcommand with connection and object overview"
```

---

### Task 5: `backup` subcommand

**Files:**
- Create: `lib/backup.sh`
- Create: `tests/integration/backup.bats`

**Interfaces:**
- Consumes: `ensure_dependencies`, `check_connection`, `list_all_databases`, `split_csv`, `die`, `db_mysqldump` from Tasks 1–2
- Produces: `cmd_backup` — entry point called by `db-ops.sh backup`; `backup_one_database "$db" "$out_file"` — helper used internally, writes a gzip of schema+data SQL for one database to `$out_file`

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration/backup.bats`:

```bash
#!/usr/bin/env bats

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose down -v
}

run_in_alpine() {
  docker run --rm --network db-ops-test-net \
    -v "$BATS_TEST_DIRNAME/../..":/work -w /work \
    alpine:3.19 sh -c "$1"
}

@test "backup creates a timestamped directory with one gz file per database" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  [ -f "$backup_dir/testdb.sql.gz" ]

  dump="$(zcat "$backup_dir/testdb.sql.gz")"
  [[ "$dump" == *"CREATE TABLE"*"products"* ]]
  [[ "$dump" == *"INSERT INTO"*"products"* ]]
  [[ "$dump" == *"CREATE"*"VIEW"*"expensive_products"* ]]
  [[ "$dump" == *"PROCEDURE"*"add_product"* ]]
  [[ "$dump" == *"TRIGGER"*"products_after_insert"* ]]
  [[ "$dump" == *"EVENT"*"cleanup_audit_log"* ]]

  rm -rf "$backup_dir"
}

@test "backup --all-databases backs up every non-system database" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --all-databases"
  [ "$status" -eq 0 ]

  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  [ -f "$backup_dir/testdb.sql.gz" ]

  rm -rf "$backup_dir"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/backup.bats`
Expected: FAIL — `lib/backup.sh` does not exist.

- [ ] **Step 3: Implement `lib/backup.sh`**

Create `lib/backup.sh`:

```sh
#!/bin/sh
# backup.sh - db-ops backup subcommand

cmd_backup() {
  ensure_dependencies
  check_connection

  if [ "$DB_ALL_DATABASES" -eq 1 ]; then
    databases="$(list_all_databases)"
  elif [ -n "$DB_DATABASE" ]; then
    databases="$(split_csv "$DB_DATABASE")"
  else
    die "Specify --database <db1,db2> or --all-databases"
  fi

  [ -n "$(printf '%s' "$databases" | tr -d '[:space:]')" ] || die "No databases to back up"

  timestamp="$(date +%Y%m%d_%H%M%S)"
  out_dir="backup_${timestamp}"
  mkdir -p "$out_dir"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    echo "Backing up database: $db"
    backup_one_database "$db" "$out_dir/${db}.sql.gz"
  done

  echo "Backup complete: $out_dir"
}

backup_one_database() {
  db="$1"
  out_file="$2"
  tmp_sql="$(mktemp)"

  db_mysqldump --no-data --routines --triggers --events "$db" >> "$tmp_sql" \
    || die "Schema dump failed for database: $db"

  db_mysqldump --no-create-info --complete-insert --skip-extended-insert \
    --hex-blob --single-transaction "$db" >> "$tmp_sql" \
    || die "Data dump failed for database: $db"

  gzip -c "$tmp_sql" > "$out_file"
  rm -f "$tmp_sql"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/backup.bats`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/backup.sh tests/integration/backup.bats
git commit -m "feat: add backup subcommand with per-database schema+data dumps"
```

---

### Task 6: `restore` subcommand (baseline, no generated-column handling yet)

**Files:**
- Create: `lib/restore.sh`
- Create: `tests/integration/restore_baseline.bats`

**Interfaces:**
- Consumes: `ensure_dependencies`, `check_connection`, `split_csv`, `confirm`, `die`, `db_mysql` from Tasks 1–2; backup files produced by Task 5
- Produces: `cmd_restore` — entry point called by `db-ops.sh restore`; `restore_one_database "$db" "$archive"` — helper, restores one database from a `.sql.gz` archive (this task's version does a direct schema+data import with no generated-column staging — Task 7 extends it)

This task proves the basic DROP/CREATE + schema/data import pipeline works end-to-end using `audit_log` (a table with no generated columns), deferring the generated-column fix to Task 7.

- [ ] **Step 1: Write the failing integration test**

Create `tests/integration/restore_baseline.bats`:

```bash
#!/usr/bin/env bats

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose down -v
}

run_in_alpine() {
  docker run --rm --network db-ops-test-net \
    -v "$BATS_TEST_DIRNAME/../..":/work -w /work \
    alpine:3.19 sh -c "$1"
}

query_testdb() {
  run_in_alpine "apk add --no-cache mariadb-client >/dev/null && mysql --ssl-mode=REQUIRED --ssl-verify-server-cert=0 -h mysql -P 3306 -uroot -prootpass -N -B -e \"$1\" testdb"
}

@test "restore recreates a table without generated columns and its rows" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"

  run query_testdb "DELETE FROM audit_log;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./db-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${backup_dir#$root/}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SHOW TABLES LIKE 'audit_log';"
  [ "$status" -eq 0 ]
  [[ "$output" == *"audit_log"* ]]

  rm -rf "$backup_dir"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/integration/restore_baseline.bats`
Expected: FAIL — `lib/restore.sh` does not exist.

- [ ] **Step 3: Implement baseline `lib/restore.sh`**

Create `lib/restore.sh`:

```sh
#!/bin/sh
# restore.sh - db-ops restore subcommand

cmd_restore() {
  ensure_dependencies
  check_connection

  [ -n "$BACKUP_DIR" ] || die "Specify --dir <backup_dir>"
  [ -d "$BACKUP_DIR" ] || die "Backup directory not found: $BACKUP_DIR"
  [ -n "$DB_DATABASE" ] || die "Specify --database <db1,db2> (explicit list required)"

  databases="$(split_csv "$DB_DATABASE")"

  printf '%s\n' "$databases" | while IFS= read -r db; do
    [ -n "$db" ] || continue
    archive="$BACKUP_DIR/${db}.sql.gz"
    [ -f "$archive" ] || die "Backup file not found: $archive"

    confirm "This will DROP and recreate database '$db'. Continue?" \
      || die "Aborted by user for database: $db"

    restore_one_database "$db" "$archive"
    echo "Restored database: $db"
  done
}

restore_one_database() {
  db="$1"
  archive="$2"
  tmp_sql="$(mktemp)"
  gzip -dc "$archive" > "$tmp_sql"

  db_mysql -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\`;" \
    || die "Failed to (re)create database: $db"

  db_mysql "$db" < "$tmp_sql" || die "Failed to import database: $db"

  rm -f "$tmp_sql"
}
```

Note: this baseline implementation imports schema+data as a single stream. It will fail for `products` (which has generated columns) — that is expected and fixed in Task 7. This test only exercises `audit_log`, which has no generated columns.

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/integration/restore_baseline.bats`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/restore.sh tests/integration/restore_baseline.bats
git commit -m "feat: add baseline restore subcommand (drop/create + schema+data import)"
```

---

### Task 7: Generated-column-safe restore

**Files:**
- Create: `lib/gencol_filter.awk`
- Create: `tests/unit/gencol_filter.bats`
- Modify: `lib/restore.sh`
- Create: `tests/integration/restore_generated_columns.bats`

**Interfaces:**
- Consumes: `restore_one_database` from Task 6; `$LIB_DIR` global from `db-ops.sh`
- Produces: `lib/gencol_filter.awk` — a `gawk` script invoked as `gawk -v mapfile=<path> -f lib/gencol_filter.awk <data.sql>`, where `mapfile` contains tab-separated `table<TAB>column` lines (one per generated column); rewrites the column-name list of matching `INSERT INTO \`table\` (...)  VALUES` statements, appending `_tmp` to any listed generated column name. `restore_one_database` is extended to split schema/data, stage `_tmp` columns, run the filter, import, then drop the `_tmp` columns.

- [ ] **Step 1: Write the failing unit test for the awk filter**

Create `tests/unit/gencol_filter.bats`:

```bash
#!/usr/bin/env bats

setup() {
  LIB_DIR="$BATS_TEST_DIRNAME/../../lib"
}

@test "gencol_filter rewrites only the generated column in the column list, not VALUES" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `products` (`id`, `name`, `price`, `price_with_tax`, `name_upper`, `thumbnail`) VALUES (1,'Widget',9.99,10.99,'WIDGET',0x89504E47);
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'price_with_tax mentioned here, not a real column');
EOF
  printf 'products\tprice_with_tax\nproducts\tname_upper\n' > "$map_file"

  run gawk -v mapfile="$map_file" -f "$LIB_DIR/gencol_filter.awk" "$data_sql"
  [ "$status" -eq 0 ]

  [[ "$output" == *'`products` (`id`, `name`, `price`, `price_with_tax_tmp`, `name_upper_tmp`, `thumbnail`) VALUES (1,'"'"'Widget'"'"',9.99,10.99,'"'"'WIDGET'"'"',0x89504E47)'* ]]
  [[ "$output" == *"price_with_tax mentioned here, not a real column"* ]]

  rm -f "$data_sql" "$map_file"
}

@test "gencol_filter leaves tables with no generated columns untouched" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'hello');
EOF
  : > "$map_file"

  run gawk -v mapfile="$map_file" -f "$LIB_DIR/gencol_filter.awk" "$data_sql"
  [ "$status" -eq 0 ]
  [ "$output" = "INSERT INTO \`audit_log\` (\`id\`, \`message\`) VALUES (1,'hello');" ]

  rm -f "$data_sql" "$map_file"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/unit/gencol_filter.bats`
Expected: FAIL — `lib/gencol_filter.awk` does not exist.

- [ ] **Step 3: Implement `lib/gencol_filter.awk`**

Create `lib/gencol_filter.awk`:

```awk
# gencol_filter.awk
# Usage: gawk -v mapfile=<table-column map file> -f gencol_filter.awk data.sql
#
# mapfile: tab-separated "table<TAB>column" lines, one per generated column
# that must be redirected to <column>_tmp inside INSERT statements produced
# with --complete-insert --skip-extended-insert. Only the column-name list
# is rewritten; the VALUES clause is left untouched so no value parsing of
# quoted strings or hex-blob literals is ever required.

BEGIN {
  if (mapfile != "") {
    while ((getline mline < mapfile) > 0) {
      split(mline, parts, "\t")
      if (parts[1] != "" && parts[2] != "") {
        gencols[parts[1] SUBSEP parts[2]] = 1
      }
    }
    close(mapfile)
  }
}

{
  line = $0
  if (match(line, /^INSERT INTO `([^`]+)` \(/, m)) {
    table = m[1]
    open_paren = index(line, "(")
    values_pos = index(line, ") VALUES")
    if (open_paren > 0 && values_pos > open_paren) {
      col_list = substr(line, open_paren + 1, values_pos - open_paren - 1)
      n = split(col_list, cols, ", ")
      out = ""
      for (i = 1; i <= n; i++) {
        col = cols[i]
        colname = col
        gsub(/`/, "", colname)
        if ((table SUBSEP colname) in gencols) {
          col = "`" colname "_tmp`"
        }
        out = (i == 1) ? col : out ", " col
      }
      line = substr(line, 1, open_paren) out substr(line, values_pos)
    }
  }
  print line
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bats tests/unit/gencol_filter.bats`
Expected: both tests PASS.

- [ ] **Step 5: Commit the awk filter**

```bash
git add lib/gencol_filter.awk tests/unit/gencol_filter.bats
git commit -m "feat: add gawk filter to redirect generated columns to _tmp columns"
```

- [ ] **Step 6: Write the failing integration test for full restore with generated columns**

Create `tests/integration/restore_generated_columns.bats`:

```bash
#!/usr/bin/env bats

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose down -v
}

run_in_alpine() {
  docker run --rm --network db-ops-test-net \
    -v "$BATS_TEST_DIRNAME/../..":/work -w /work \
    alpine:3.19 sh -c "$1"
}

query_testdb() {
  run_in_alpine "apk add --no-cache mariadb-client >/dev/null && mysql --ssl-mode=REQUIRED --ssl-verify-server-cert=0 -h mysql -P 3306 -uroot -prootpass -N -B -e \"$1\" testdb"
}

@test "backup then restore round-trips generated columns, blobs, and leaves no _tmp columns" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  before_checksum="$(query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"; echo "$output")"

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run query_testdb "DROP TABLE IF EXISTS products;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./db-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"
  [ "$status" -eq 0 ]
  [ "$output" = "$before_checksum" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='testdb' AND COLUMN_NAME LIKE '%_tmp';"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  rm -rf "$backup_dir"
}

@test "restore is idempotent when run twice against the same backup" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run run_in_alpine "./db-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run run_in_alpine "./db-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]

  rm -rf "$backup_dir"
}
```

- [ ] **Step 7: Run test to verify it fails**

Run: `bats tests/integration/restore_generated_columns.bats`
Expected: FAIL — restoring `products` errors because `price_with_tax`/`name_upper` are generated columns and the baseline `restore_one_database` tries to insert directly into them.

- [ ] **Step 8: Extend `restore.sh` with generated-column staging**

Replace `restore_one_database` in `lib/restore.sh` with:

```sh
restore_one_database() {
  db="$1"
  archive="$2"
  tmp_sql="$(mktemp)"
  gzip -dc "$archive" > "$tmp_sql"

  db_mysql -e "DROP DATABASE IF EXISTS \`${db}\`; CREATE DATABASE \`${db}\`;" \
    || die "Failed to (re)create database: $db"

  schema_sql="$(mktemp)"
  data_sql="$(mktemp)"
  awk -v schema_out="$schema_sql" -v data_out="$data_sql" '
    /^INSERT INTO / { in_insert = 1 }
    in_insert { print >> data_out; next }
    { print >> schema_out }
  ' "$tmp_sql"

  db_mysql "$db" < "$schema_sql" || die "Failed to import schema for database: $db"

  map_raw="$(mktemp)"
  map_file="$(mktemp)"
  db_mysql -N -B -e "
    SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='${db}'
      AND GENERATION_EXPRESSION IS NOT NULL
      AND GENERATION_EXPRESSION != '';
  " > "$map_raw"

  : > "$map_file"
  while IFS="$(printf '\t')" read -r tbl col coltype; do
    [ -n "$tbl" ] || continue
    printf '%s\t%s\n' "$tbl" "$col" >> "$map_file"
    db_mysql "$db" -e "ALTER TABLE \`${tbl}\` ADD COLUMN \`${col}_tmp\` ${coltype} NULL;" \
      || die "Failed to add temp column ${col}_tmp on ${tbl}"
  done < "$map_raw"

  if [ -s "$map_file" ]; then
    filtered_data_sql="$(mktemp)"
    gawk -v mapfile="$map_file" -f "$LIB_DIR/gencol_filter.awk" "$data_sql" > "$filtered_data_sql"
    db_mysql "$db" < "$filtered_data_sql" || die "Failed to import data for database: $db"
    rm -f "$filtered_data_sql"

    while IFS="$(printf '\t')" read -r tbl col; do
      [ -n "$tbl" ] || continue
      db_mysql "$db" -e "ALTER TABLE \`${tbl}\` DROP COLUMN \`${col}_tmp\`;" \
        || die "Failed to drop temp column ${col}_tmp on ${tbl}"
    done < "$map_file"
  else
    db_mysql "$db" < "$data_sql" || die "Failed to import data for database: $db"
  fi

  rm -f "$tmp_sql" "$schema_sql" "$data_sql" "$map_file" "$map_raw"
}
```

- [ ] **Step 9: Run test to verify it passes**

Run: `bats tests/integration/restore_generated_columns.bats tests/integration/restore_baseline.bats`
Expected: all tests PASS — generated columns round-trip correctly, no `_tmp` columns remain, restore is idempotent, and the baseline (non-generated-column) restore from Task 6 still passes.

- [ ] **Step 10: Commit**

```bash
git add lib/restore.sh tests/integration/restore_generated_columns.bats
git commit -m "feat: stage generated columns through _tmp columns during restore"
```

---

### Task 8: Full end-to-end validation and usage docs

**Files:**
- Create: `tests/integration/full_roundtrip.bats`
- Create: `README.md`

**Interfaces:**
- Consumes: `cmd_info`, `cmd_backup`, `cmd_restore` from Tasks 4–7
- Produces: a documented, fully validated CLI (no new shared interfaces — this task is validation + docs only)

- [ ] **Step 1: Write the full end-to-end bats test**

Create `tests/integration/full_roundtrip.bats`:

```bash
#!/usr/bin/env bats

setup_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose up -d --wait
}

teardown_file() {
  cd "$BATS_TEST_DIRNAME"
  docker compose down -v
}

run_in_alpine() {
  docker run --rm --network db-ops-test-net \
    -v "$BATS_TEST_DIRNAME/../..":/work -w /work \
    alpine:3.19 sh -c "$1"
}

query_testdb() {
  run_in_alpine "apk add --no-cache mariadb-client >/dev/null && mysql --ssl-mode=REQUIRED --ssl-verify-server-cert=0 -h mysql -P 3306 -uroot -prootpass -N -B -e \"$1\" testdb"
}

@test "end to end: info, backup, restore reproduce all object types and data" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./db-ops.sh info --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]

  run run_in_alpine "./db-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run query_testdb "DROP DATABASE testdb;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./db-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
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

  rm -rf "$backup_dir"
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `bats tests/integration/full_roundtrip.bats`
Expected: PASS (this test composes already-implemented behavior from Tasks 4–7; if any assertion fails, fix the corresponding `lib/*.sh` file before proceeding — do not weaken the test).

- [ ] **Step 3: Write `README.md`**

Create `README.md`:

```markdown
# db-ops

A single POSIX-shell tool for backing up and restoring MySQL databases from
a bare Alpine environment, over a TLS connection that trusts self-signed
certificates, with correct handling of generated (virtual/stored) columns
and BLOB data.

## Requirements

Runs on any Alpine container with `apk` available and network access to
the target MySQL server. All dependencies (`mariadb-client`,
`mariadb-connector-c`, `gzip`, `gawk`) are installed automatically on
first run.

## Usage

\`\`\`sh
# Check connectivity and see what would be backed up
./db-ops.sh info --host mysql --port 3306 --user root --password secret --database mydb

# Back up one or more databases (creates backup_<timestamp>/<db>.sql.gz)
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --database db1,db2
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --all-databases

# Restore one or more databases from a backup directory (destructive: DROP + CREATE)
./db-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb
./db-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb --force
\`\`\`

## Configuration file

Instead of passing flags, use a KEY=VALUE config file:

\`\`\`sh
# db.conf
DB_HOST=mysql.example.internal
DB_PORT=3306
DB_USER=backup_user
DB_PASSWORD=secret
\`\`\`

\`\`\`sh
./db-ops.sh info --config db.conf --database mydb
\`\`\`

Command-line flags always override values from the config file. Prefer
setting `DB_PASSWORD` as an environment variable over `--password` or the
config file, to avoid leaving credentials in shell history or on disk.

## TLS

All connections use `--ssl-mode=REQUIRED --ssl-verify-server-cert=0`:
traffic is encrypted, but the server's certificate is not validated,
so self-signed certificates work without extra configuration.

## Generated columns

Backups always include full column definitions in `CREATE TABLE`
statements. During restore, generated (virtual/stored) columns are never
modified directly: an additive `<column>_tmp` column temporarily receives
the dumped value, and is dropped once the database recomputes the real
generated column from the row's other data. This means indexes, unique
constraints, and foreign keys on the table are never affected.

## Running the tests

Unit tests (no database required):

\`\`\`sh
brew install bats-core   # one-time, macOS
bats tests/unit
\`\`\`

Integration tests (requires Docker):

\`\`\`sh
bats tests/integration
\`\`\`
```

- [ ] **Step 4: Commit**

```bash
git add tests/integration/full_roundtrip.bats README.md
git commit -m "test: add full end-to-end validation and usage documentation"
```

---

## Self-Review Notes

- **Spec coverage:** apk auto-install (Task 2), self-signed TLS with no cert verification (Task 2), full DDL+DML incl. views/routines/triggers/events (Tasks 5, 8), hex-blob binary safety (Task 5, verified in Task 7), generated-column-safe restore without touching indexes (Task 7), multi-database + `--all-databases` (Task 5), timestamped directory with one file per db (Task 5), explicit `--database` required for restore + confirmation/`--force` (Task 6), `info` subcommand (Task 4) — all covered.
- **Placeholder scan:** no TBD/TODO markers; every step has runnable code.
- **Type/name consistency:** `cmd_info`/`cmd_backup`/`cmd_restore` match `db-ops.sh` dispatch; `backup_one_database`/`restore_one_database` signatures consistent across Tasks 5–7; `gencol_filter.awk`'s `mapfile` format (`table\tcolumn`) matches what `restore.sh` writes in Task 7 Step 8.
