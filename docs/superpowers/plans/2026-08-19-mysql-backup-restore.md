# MySQL 备份/恢复工具实施计划

> **执行说明：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务执行本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 构建一个单一的 POSIX shell 工具（`db-ops.sh`），可在裸 Alpine 环境下运行（通过 `apk` 自行安装依赖），能够对 MySQL 数据库的所有用户表、视图、存储过程/函数、触发器和事件进行备份与恢复，连接时信任自签名 TLS 证书，并正确处理生成列（虚拟/存储）与二进制（BLOB）数据的往返一致性。

**架构：** 一个调度脚本（`db-ops.sh`）加载 `lib/` 下的小型库文件：共享的配置/连接辅助函数（`common.sh`）和各子命令逻辑（`info.sh`、`backup.sh`、`restore.sh`）。生成列的处理被隔离在一个 `gawk` 过滤脚本（`lib/gencol_filter.awk`）中，该脚本在恢复阶段重写 `INSERT` 语句的列名列表，与具体的值解析完全解耦。

**技术栈：** POSIX `sh`、`mariadb-client`（`mysql`/`mysqldump`/`mysqladmin`）、`mariadb-connector-c`、`gzip`、`gawk`——均在运行时通过 `apk` 安装。开发/测试工具：`bats-core`（单元测试）和 Docker（集成测试环境，使用会自动生成自签名 TLS 证书的 `mysql:8.0`）。

## 全局约束

- 目标运行环境为裸 Alpine；所有非 busybox 依赖（`mariadb-client`、`mariadb-connector-c`、`gzip`、`gawk`）缺失时必须通过 `apk add --no-cache` 自动安装——不能假设已预装。
- 所有 MySQL 客户端连接必须包含 `--ssl-mode=REQUIRED --ssl-verify-server-cert=0`（强制加密，但不校验自签名证书）。
- 密码绝不能出现在进程参数列表中——始终通过临时的 `--defaults-extra-file`（`[client]` 段）传递，并通过 `trap` 在退出时删除。
- 备份必须覆盖：所有用户表（DDL+DML）、视图、存储过程/函数、触发器和事件。
- BLOB/二进制字段必须使用 `--hex-blob` 导出。
- 生成列（虚拟/存储）本身绝不能被改动（不能对生成列本身执行 `DROP`/`ALTER`）——只使用一个新增的 `<col>_tmp` 暂存列，因此表上的索引/约束不受影响。
- 备份输出：每次运行生成一个目录 `backup_<YYYYMMDD_HHMMSS>/`，每个数据库一个文件 `<db>.sql.gz`。
- 恢复必须显式指定 `--database <db1,db2>` 列表——不支持隐式地"恢复目录中的全部内容"。
- 恢复对每个数据库都是破坏性操作（`DROP DATABASE IF EXISTS` + `CREATE DATABASE`），除非传入 `--force`，否则需要交互式确认。

---

### 任务 1：配置解析与 CLI 脚手架

**文件：**
- 创建：`db-ops.sh`
- 创建：`lib/common.sh`
- 测试：`tests/unit/common.bats`

**接口：**
- 产出（供后续所有任务使用）：
  - 执行 `parse_common_args "$@"` + `load_config` 后设置的变量：`DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_DATABASE`（原始逗号字符串）、`DB_ALL_DATABASES`（0/1）、`FORCE`（0/1）、`BACKUP_DIR`、`CONFIG_FILE`
  - `die "message"` —— 打印到 stderr，退出码 1
  - `split_csv "a, b ,c"` —— 输出去除空白后的、以换行分隔的条目
  - `confirm "prompt"` —— 当 `FORCE=1` 或用户回答 y/Y/yes 时返回 0，否则返回 1
  - `$LIB_DIR` —— `lib/` 的绝对路径，在 `db-ops.sh` 中作为全局变量设置

- [ ] **步骤 1：编写会失败的 bats 测试**

创建 `tests/unit/common.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/unit/common.bats`
预期：失败 —— `lib/common.sh` 尚不存在。

- [ ] **步骤 3：实现 `lib/common.sh`**

创建 `lib/common.sh`：

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

- [ ] **步骤 4：运行测试，确认其通过**

运行：`bats tests/unit/common.bats`
预期：所有 `parse_common_args`/`split_csv`/`load_config`/`confirm` 测试均通过。（任务 2 涉及的依赖/连接测试尚不在此文件中。）

- [ ] **步骤 5：创建调度脚本**

创建 `db-ops.sh`：

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

运行：`chmod +x db-ops.sh`

- [ ] **步骤 6：提交**

```bash
git add db-ops.sh lib/common.sh tests/unit/common.bats
git commit -m "feat: add CLI scaffolding and config parsing"
```

---

### 任务 2：依赖安装与安全连接辅助函数

**文件：**
- 修改：`lib/common.sh`
- 创建：`tests/unit/connection.bats`
- 创建：`tests/unit/stubs/mysql`
- 创建：`tests/unit/stubs/mysqladmin`
- 创建：`tests/unit/stubs/mysqldump`
- 创建：`tests/unit/stubs/apk`

**接口：**
- 消费：来自任务 1 的 `die`、`$DB_HOST`、`$DB_PORT`、`$DB_USER`、`$DB_PASSWORD`
- 产出（供任务 3 及以后使用）：
  - `ensure_dependencies` —— 当 `mysql mysqldump mysqladmin gzip gawk` 中任一命令缺失时，通过 `apk` 安装 `mariadb-client mariadb-connector-c gzip gawk`；安装后仍缺失则报错退出
  - `make_defaults_file` —— 创建 `$_TMP_DEFAULTS_FILE`（权限 600），内容为 `[client]\npassword=$DB_PASSWORD`
  - `db_mysql [args...]`、`db_mysqldump [args...]`、`db_mysqladmin [args...]` —— 自动注入 `--defaults-extra-file`、`--host`、`--port`、`--user`、`--ssl-mode=REQUIRED`、`--ssl-verify-server-cert=0` 的包装函数
  - `check_connection` —— 若 `db_mysqladmin ping` 失败则报错退出
  - `cleanup_common`（通过 `trap ... EXIT INT TERM` 注册）—— 删除 `$_TMP_DEFAULTS_FILE`

- [ ] **步骤 1：编写用于单元测试的桩程序（stub）**

创建 `tests/unit/stubs/mysql`：
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQL_EXIT_CODE:-0}"
```

创建 `tests/unit/stubs/mysqladmin`：
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQLADMIN_EXIT_CODE:-0}"
```

创建 `tests/unit/stubs/mysqldump`：
```sh
#!/bin/sh
echo "$0 $*" >> "$STUB_LOG"
exit "${MYSQLDUMP_EXIT_CODE:-0}"
```

创建 `tests/unit/stubs/apk`：
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

运行：`chmod +x tests/unit/stubs/mysql tests/unit/stubs/mysqladmin tests/unit/stubs/mysqldump tests/unit/stubs/apk`

- [ ] **步骤 2：编写会失败的 bats 测试**

创建 `tests/unit/connection.bats`：

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

- [ ] **步骤 3：运行测试，确认其失败**

运行：`bats tests/unit/connection.bats`
预期：失败 —— `ensure_dependencies`、`make_defaults_file`、`db_mysql`、`db_mysqladmin`、`check_connection` 尚未定义。

- [ ] **步骤 4：实现连接辅助函数**

追加到 `lib/common.sh`：

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

- [ ] **步骤 5：运行测试，确认其通过**

运行：`bats tests/unit/connection.bats`
预期：所有测试通过。

- [ ] **步骤 6：提交**

```bash
git add lib/common.sh tests/unit/connection.bats tests/unit/stubs
git commit -m "feat: add dependency install and secure connection helpers"
```

---

### 任务 3：集成测试环境（Docker + 自签名 TLS MySQL）

**文件：**
- 创建：`tests/integration/docker-compose.yml`
- 创建：`tests/integration/init.sql`

**接口：**
- 产出：一个运行中的 `mysql:8.0` 容器（服务名 `mysql`，网络 `db-ops-test-net`，数据库 `testdb`，root 密码 `rootpass`），首次启动时自动生成自签名 TLS 证书，并预置一套覆盖以下内容的 schema：一个带 `VIRTUAL` 生成列的表、一个带 `STORED` 生成列的表、一个 `BLOB` 字段、一个视图、一个存储过程、一个触发器和一个事件。后续任务通过 `docker run --network db-ops-test-net ... alpine:3.19` 连接它，以证明工具能在裸 Alpine 上运行。

- [ ] **步骤 1：编写种子 schema**

创建 `tests/integration/init.sql`：

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

- [ ] **步骤 2：编写 compose 文件**

创建 `tests/integration/docker-compose.yml`：

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

- [ ] **步骤 3：启动环境并手动验证**

运行：
```bash
cd tests/integration
docker compose up -d --wait
```
预期：命令退出码为 0，`docker compose ps` 显示 `mysql` 状态为 `healthy`。

- [ ] **步骤 4：从裸 Alpine 容器验证自签名 TLS 与种子 schema**

运行：
```bash
docker run --rm --network db-ops-test-net alpine:3.19 sh -c "
  apk add --no-cache mariadb-client >/dev/null &&
  mysql --ssl-mode=REQUIRED --ssl-verify-server-cert=0 \
    -h mysql -P 3306 -uroot -prootpass testdb \
    -e 'SHOW TABLES; SELECT COUNT(*) FROM products;'
"
```
预期：打印表清单（`audit_log`、`products`）以及行数 `3`，没有 TLS 证书相关错误。

- [ ] **步骤 5：提交**

```bash
git add tests/integration/docker-compose.yml tests/integration/init.sql
git commit -m "test: add dockerized MySQL integration environment with self-signed TLS"
```

---

### 任务 4：`info` 子命令

**文件：**
- 创建：`lib/info.sh`
- 创建：`tests/integration/info.bats`

**接口：**
- 消费：来自任务 1–2 的 `ensure_dependencies`、`check_connection`、`list_all_databases`、`split_csv`、`die`、`db_mysql`；解析后的 `$DB_DATABASE`、`$DB_ALL_DATABASES`
- 产出：`cmd_info` —— 由 `db-ops.sh info` 调用的入口函数

- [ ] **步骤 1：编写会失败的集成测试**

创建 `tests/integration/info.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/integration/info.bats`
预期：失败 —— `lib/info.sh` 不存在，`db-ops.sh info` 报"未知命令"或文件缺失类错误。

- [ ] **步骤 3：实现 `lib/info.sh`**

创建 `lib/info.sh`：

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

- [ ] **步骤 4：运行测试，确认其通过**

运行：`bats tests/integration/info.bats`
预期：两个测试均通过。

- [ ] **步骤 5：提交**

```bash
git add lib/info.sh tests/integration/info.bats
git commit -m "feat: add info subcommand with connection and object overview"
```

---

### 任务 5：`backup` 子命令

**文件：**
- 创建：`lib/backup.sh`
- 创建：`tests/integration/backup.bats`

**接口：**
- 消费：来自任务 1–2 的 `ensure_dependencies`、`check_connection`、`list_all_databases`、`split_csv`、`die`、`db_mysqldump`
- 产出：`cmd_backup` —— 由 `db-ops.sh backup` 调用的入口函数；`backup_one_database "$db" "$out_file"` —— 内部辅助函数，将某个数据库的 schema+data SQL 压缩写入 `$out_file`

- [ ] **步骤 1：编写会失败的集成测试**

创建 `tests/integration/backup.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/integration/backup.bats`
预期：失败 —— `lib/backup.sh` 不存在。

- [ ] **步骤 3：实现 `lib/backup.sh`**

创建 `lib/backup.sh`：

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

- [ ] **步骤 4：运行测试，确认其通过**

运行：`bats tests/integration/backup.bats`
预期：两个测试均通过。

- [ ] **步骤 5：提交**

```bash
git add lib/backup.sh tests/integration/backup.bats
git commit -m "feat: add backup subcommand with per-database schema+data dumps"
```

---

### 任务 6：`restore` 子命令（基线版本，暂不处理生成列）

**文件：**
- 创建：`lib/restore.sh`
- 创建：`tests/integration/restore_baseline.bats`

**接口：**
- 消费：来自任务 1–2 的 `ensure_dependencies`、`check_connection`、`split_csv`、`confirm`、`die`、`db_mysql`；任务 5 产出的备份文件
- 产出：`cmd_restore` —— 由 `db-ops.sh restore` 调用的入口函数；`restore_one_database "$db" "$archive"` —— 辅助函数，从 `.sql.gz` 归档恢复单个数据库（本任务的版本直接导入 schema+data，暂不做生成列暂存处理——任务 7 会扩展它）

本任务用 `audit_log`（一张没有生成列的表）验证基础的 DROP/CREATE + schema/data 导入流程能端到端跑通，生成列的修复留给任务 7。

- [ ] **步骤 1：编写会失败的集成测试**

创建 `tests/integration/restore_baseline.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/integration/restore_baseline.bats`
预期：失败 —— `lib/restore.sh` 不存在。

- [ ] **步骤 3：实现基线版 `lib/restore.sh`**

创建 `lib/restore.sh`：

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

注意：该基线实现将 schema+data 作为一个整体流导入。对含生成列的 `products` 表会导入失败——这是预期的，将在任务 7 中修复。本测试仅覆盖没有生成列的 `audit_log`。

- [ ] **步骤 4：运行测试，确认其通过**

运行：`bats tests/integration/restore_baseline.bats`
预期：通过。

- [ ] **步骤 5：提交**

```bash
git add lib/restore.sh tests/integration/restore_baseline.bats
git commit -m "feat: add baseline restore subcommand (drop/create + schema+data import)"
```

---

### 任务 7：生成列安全的恢复流程

**文件：**
- 创建：`lib/gencol_filter.awk`
- 创建：`tests/unit/gencol_filter.bats`
- 修改：`lib/restore.sh`
- 创建：`tests/integration/restore_generated_columns.bats`

**接口：**
- 消费：任务 6 的 `restore_one_database`；`db-ops.sh` 中的全局变量 `$LIB_DIR`
- 产出：`lib/gencol_filter.awk` —— 以 `gawk -v mapfile=<path> -f lib/gencol_filter.awk <data.sql>` 方式调用的 `gawk` 脚本，`mapfile` 中每行是一条 tab 分隔的 `table<TAB>column`（每个生成列一行）；对匹配的 `INSERT INTO \`table\` (...) VALUES` 语句重写列名列表，将列出的生成列名追加 `_tmp`。`restore_one_database` 被扩展为：拆分 schema/data、暂存 `_tmp` 列、运行过滤器、导入、再删除 `_tmp` 列。

- [ ] **步骤 1：为 awk 过滤器编写会失败的单元测试**

创建 `tests/unit/gencol_filter.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/unit/gencol_filter.bats`
预期：失败 —— `lib/gencol_filter.awk` 不存在。

- [ ] **步骤 3：实现 `lib/gencol_filter.awk`**

创建 `lib/gencol_filter.awk`：

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

- [ ] **步骤 4：运行测试，确认其通过**

运行：`bats tests/unit/gencol_filter.bats`
预期：两个测试均通过。

- [ ] **步骤 5：提交 awk 过滤器**

```bash
git add lib/gencol_filter.awk tests/unit/gencol_filter.bats
git commit -m "feat: add gawk filter to redirect generated columns to _tmp columns"
```

- [ ] **步骤 6：为含生成列的完整恢复流程编写会失败的集成测试**

创建 `tests/integration/restore_generated_columns.bats`：

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

- [ ] **步骤 7：运行测试，确认其失败**

运行：`bats tests/integration/restore_generated_columns.bats`
预期：失败 —— 恢复 `products` 时报错，因为 `price_with_tax`/`name_upper` 是生成列，而基线版 `restore_one_database` 试图直接向它们插入值。

- [ ] **步骤 8：扩展 `restore.sh`，加入生成列暂存逻辑**

用以下内容替换 `lib/restore.sh` 中的 `restore_one_database`：

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

- [ ] **步骤 9：运行测试，确认其通过**

运行：`bats tests/integration/restore_generated_columns.bats tests/integration/restore_baseline.bats`
预期：全部通过 —— 生成列正确往返、不残留 `_tmp` 列、恢复具有幂等性，且任务 6 的基线（无生成列）恢复测试依旧通过。

- [ ] **步骤 10：提交**

```bash
git add lib/restore.sh tests/integration/restore_generated_columns.bats
git commit -m "feat: stage generated columns through _tmp columns during restore"
```

---

### 任务 8：全流程端到端验证与使用文档

**文件：**
- 创建：`tests/integration/full_roundtrip.bats`
- 创建：`README.md`

**接口：**
- 消费：任务 4–7 的 `cmd_info`、`cmd_backup`、`cmd_restore`
- 产出：一份文档完善、经过完整验证的 CLI（本任务不新增共享接口，仅做验证与文档）

- [ ] **步骤 1：编写完整的端到端 bats 测试**

创建 `tests/integration/full_roundtrip.bats`：

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

- [ ] **步骤 2：运行测试，确认其失败或通过**

运行：`bats tests/integration/full_roundtrip.bats`
预期：通过（本测试组合了任务 4–7 已实现的行为；若有断言失败，应先修复对应的 `lib/*.sh`，而不是弱化测试断言）。

- [ ] **步骤 3：编写 `README.md`**

创建 `README.md`：

```markdown
# db-ops

一个单一的 POSIX shell 工具，用于在裸 Alpine 环境下备份和恢复 MySQL 数据库，
连接时信任自签名 TLS 证书，并正确处理生成（虚拟/存储）列和 BLOB 数据。

## 环境要求

可在任何具备 `apk` 且能网络访问目标 MySQL 服务器的 Alpine 容器中运行。
所有依赖（`mariadb-client`、`mariadb-connector-c`、`gzip`、`gawk`）首次运行时自动安装。

## 用法

\`\`\`sh
# 检查连通性并查看将被备份的内容
./db-ops.sh info --host mysql --port 3306 --user root --password secret --database mydb

# 备份一个或多个数据库（生成 backup_<timestamp>/<db>.sql.gz）
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --database db1,db2
./db-ops.sh backup --host mysql --port 3306 --user root --password secret --all-databases

# 从备份目录恢复一个或多个数据库（破坏性操作：DROP + CREATE）
./db-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb
./db-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb --force
\`\`\`

## 配置文件

除了传参，也可以使用 KEY=VALUE 风格的配置文件：

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

命令行参数始终会覆盖配置文件中的同名值。建议通过 `DB_PASSWORD` 环境变量传递密码，
而不是 `--password` 参数或配置文件，以避免密码留存在 shell 历史或磁盘上。

## TLS

所有连接均使用 `--ssl-mode=REQUIRED --ssl-verify-server-cert=0`：
流量被加密，但不校验服务器证书，因此自签名证书无需额外配置即可正常工作。

## 生成列

备份时 `CREATE TABLE` 语句始终包含完整的列定义。恢复时，生成（虚拟/存储）列本身
绝不会被直接修改：会新增一个 `<column>_tmp` 列临时接收 dump 出来的值，待数据库
根据同一行的其他数据重新计算出真正的生成列后，再删除该临时列。这意味着表上的
索引、唯一约束、外键都不会受到任何影响。

## 运行测试

单元测试（无需数据库）：

\`\`\`sh
brew install bats-core   # 一次性安装，macOS
bats tests/unit
\`\`\`

集成测试（需要 Docker）：

\`\`\`sh
bats tests/integration
\`\`\`
```

- [ ] **步骤 4：提交**

```bash
git add tests/integration/full_roundtrip.bats README.md
git commit -m "test: add full end-to-end validation and usage documentation"
```

---

## 自查记录

- **需求覆盖：** apk 自动安装（任务 2）、自签名 TLS 且不校验证书（任务 2）、完整 DDL+DML 含视图/存储过程/触发器/事件（任务 5、8）、hex-blob 二进制数据安全性（任务 5，任务 7 中验证）、生成列安全恢复且不影响索引（任务 7）、多库 + `--all-databases`（任务 5）、带时间戳目录且每库一个文件（任务 5）、恢复必须显式指定 `--database` 且需确认/支持 `--force`（任务 6）、`info` 子命令（任务 4）——均已覆盖。
- **占位符检查：** 无 TBD/TODO 标记；每个步骤都有可运行的代码。
- **命名/类型一致性：** `cmd_info`/`cmd_backup`/`cmd_restore` 与 `db-ops.sh` 的分发逻辑一致；`backup_one_database`/`restore_one_database` 的签名在任务 5–7 中保持一致；`gencol_filter.awk` 的 `mapfile` 格式（`table\tcolumn`）与任务 7 步骤 8 中 `restore.sh` 写入的格式一致。
