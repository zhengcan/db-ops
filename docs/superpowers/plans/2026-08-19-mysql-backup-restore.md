# MySQL 备份/恢复工具实施计划

> **执行说明：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务执行本计划。步骤使用复选框（`- [ ]`）语法进行跟踪。

**目标：** 构建**单一文件** `my-ops.sh`（POSIX shell），可在裸 Alpine 环境下运行（通过 `apk` 自行安装依赖），能够对 MySQL 数据库的所有用户表、视图、存储过程/函数、触发器和事件进行备份与恢复，连接时信任自签名 TLS 证书，并正确处理生成列（虚拟/存储）与二进制（BLOB）数据的往返一致性。

**架构：** 所有逻辑（配置解析、依赖安装、连接辅助、`info`/`backup`/`restore` 子命令、生成列过滤的 awk 程序）都写在同一个 `my-ops.sh` 文件中，便于单文件分发/部署（如 `scp`/`curl` 直接拷贝到目标机器）。生成列过滤逻辑以 shell 变量形式内嵌 awk 程序文本（而非独立的 `.awk` 文件），通过 `gawk -v mapfile=... "$GENCOL_AWK_PROGRAM" data.sql` 调用。脚本顶部提供 `DB_OPS_TEST` 环境变量守卫：当该变量为 `1` 时，`source` 脚本只加载函数定义、不执行 `main`，供测试直接调用内部函数。

**技术栈：** POSIX `sh`、`mariadb-client`（`mysql`/`mysqldump`/`mysqladmin`）、`mariadb-connector-c`、`gzip`、`gawk`——均在运行时通过 `apk` 安装。开发/测试工具：`bats-core`（单元测试）和 Docker（集成测试环境，使用会自动生成自签名 TLS 证书的 `mysql:8`）。

## 全局约束

- 交付物必须是**单一文件** `my-ops.sh`——不使用 `lib/` 目录或独立的 `.awk` 文件；所有函数与 awk 程序都内嵌在这一个文件中。
- 目标运行环境为裸 Alpine；所有非 busybox 依赖（`mariadb-client`、`mariadb-connector-c`、`gzip`、`gawk`）缺失时必须通过 `apk add --no-cache` 自动安装——不能假设已预装。
- 所有 MySQL 客户端连接必须包含 `--ssl --skip-ssl-verify-server-cert`（强制加密，但不校验自签名证书）。
- 密码绝不能出现在进程参数列表中——始终通过临时的 `--defaults-extra-file`（`[client]` 段）传递，并通过 `trap` 在退出时删除。
- 备份必须覆盖：所有用户表（DDL+DML）、视图、存储过程/函数、触发器和事件。
- BLOB/二进制字段必须使用 `--hex-blob` 导出。
- 生成列（虚拟/存储）本身绝不能被改动（不能对生成列本身执行 `DROP`/`ALTER`）——只使用一个新增的 `<col>_tmp` 暂存列，因此表上的索引/约束不受影响。
- 备份输出：每次运行生成一个目录 `backup_<YYYYMMDD_HHMMSS>/`，每个数据库一个文件 `<db>.sql.gz`；支持 `--dir <path>` 指定该目录创建在哪个基础路径下（默认当前目录）。
- 恢复必须显式指定 `--database <db1,db2>` 列表——不支持隐式地"恢复目录中的全部内容"。
- 恢复对每个数据库都是破坏性操作（`DROP DATABASE IF EXISTS` + `CREATE DATABASE`），除非传入 `--force`，否则需要交互式确认。
- 直接在 `main` 分支上开发（本仓库为全新个人仓库，无远程，用户已确认无需创建独立分支）。

---

### 任务 1：单文件脚手架 —— 配置解析 + 依赖安装 + 连接辅助

**文件：**
- 创建：`my-ops.sh`
- 创建：`tests/unit/common.bats`
- 创建：`tests/unit/stubs/mysql`
- 创建：`tests/unit/stubs/mysqladmin`
- 创建：`tests/unit/stubs/mysqldump`
- 创建：`tests/unit/stubs/apk`

**接口：**
- 产出（供后续所有任务使用，均定义在 `my-ops.sh` 内）：
  - 变量：`DB_HOST`、`DB_PORT`、`DB_USER`、`DB_PASSWORD`、`DB_DATABASE`、`DB_ALL_DATABASES`（0/1）、`FORCE`（0/1）、`BACKUP_DIR`、`CONFIG_FILE`、`_TMP_DEFAULTS_FILE`
  - `die "message"` —— 打印到 stderr，退出码 1
  - `parse_common_args "$@"` —— 解析 `--config --host --port --user --password --database --all-databases --force --dir`
  - `load_config` —— 若 `$CONFIG_FILE` 非空则 `source` 它（KEY=VALUE 格式）
  - `split_csv "a, b ,c"` —— 输出去除空白后的、以换行分隔的条目
  - `confirm "prompt"` —— `FORCE=1` 或用户回答 y/Y/yes 时返回 0，否则返回 1
  - `ensure_dependencies` —— 缺失 `mysql mysqldump mysqladmin gzip gawk` 任一项时通过 `apk add --no-cache mariadb-client mariadb-connector-c gzip gawk` 安装
  - `make_defaults_file` —— 生成 `$_TMP_DEFAULTS_FILE`（权限 600，内容 `[client]\npassword=$DB_PASSWORD`）
  - `db_mysql [args...]` / `db_mysqldump [args...]` / `db_mysqladmin [args...]` —— 自动注入 `--defaults-extra-file --host --port --user --ssl --skip-ssl-verify-server-cert` 的包装函数
  - `check_connection` —— `db_mysqladmin ping` 失败则报错退出
  - `list_all_databases` —— 查询 `information_schema.SCHEMATA` 排除系统库
  - 测试守卫：脚本文件末尾 `if [ "${DB_OPS_TEST:-0}" != "1" ]; then main "$@"; fi`，测试文件 `export DB_OPS_TEST=1` 后再 `. ./my-ops.sh`，即可只加载函数、不触发 `main`

- [ ] **步骤 1：编写会失败的 bats 测试**

创建 `tests/unit/common.bats`：

```bash
#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  export DB_OPS_TEST=1
  # shellcheck disable=SC1090
  . "$SCRIPT"
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
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; FORCE=0; echo y | confirm "Proceed?"'
  [ "$status" -eq 0 ]
}

@test "confirm returns failure when user answers n" {
  run bash -c 'export DB_OPS_TEST=1; . "'"$SCRIPT"'"; FORCE=0; echo n | confirm "Proceed?"'
  [ "$status" -eq 1 ]
}
```

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/unit/common.bats`
预期：失败 —— `my-ops.sh` 尚不存在。

- [ ] **步骤 3：编写用于依赖/连接测试的桩程序（stub）**

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

- [ ] **步骤 4：将依赖/连接测试追加到同一个 bats 文件**

追加到 `tests/unit/common.bats`（在 `setup()` 内新增桩程序 PATH 注入，不影响已有测试——已有测试不依赖真实 mysql 二进制）：

```bash
@test "db_mysqladmin invokes mysqladmin with required SSL flags and connection args" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  STUB_LOG="$(mktemp)"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" \
    sh -c ". '$SCRIPT'; DB_HOST=testhost DB_PORT=3306 DB_USER=testuser DB_PASSWORD=testpass db_mysqladmin ping"
  [ "$status" -eq 0 ]
  grep -q -- "--ssl" "$STUB_LOG"
  grep -q -- "--skip-ssl-verify-server-cert" "$STUB_LOG"
  grep -q -- "--host=testhost" "$STUB_LOG"
  grep -q -- "--port=3306" "$STUB_LOG"
  grep -q -- "--user=testuser" "$STUB_LOG"
  grep -q -- "ping" "$STUB_LOG"
  rm -f "$STUB_LOG"
}

@test "make_defaults_file writes password into a client section file with mode 600" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 sh -c "
    . '$SCRIPT'
    DB_PASSWORD=testpass make_defaults_file
    grep -q '^password=testpass\$' \"\$_TMP_DEFAULTS_FILE\" || exit 1
    perms=\$(stat -f '%Lp' \"\$_TMP_DEFAULTS_FILE\" 2>/dev/null || stat -c '%a' \"\$_TMP_DEFAULTS_FILE\")
    [ \"\$perms\" = '600' ] || exit 1
  "
  [ "$status" -eq 0 ]
}

@test "check_connection fails when mysqladmin ping stub returns error" {
  STUB_DIR="$BATS_TEST_DIRNAME/stubs"
  run env PATH="$STUB_DIR:$PATH" DB_OPS_TEST=1 MYSQLADMIN_EXIT_CODE=1 STUB_LOG="$(mktemp)" \
    sh -c ". '$SCRIPT'; DB_HOST=h DB_PORT=1 DB_USER=u DB_PASSWORD=p check_connection"
  [ "$status" -eq 1 ]
}

@test "ensure_dependencies installs missing packages via apk" {
  fake_bin="$(mktemp -d)"
  cp "$BATS_TEST_DIRNAME/stubs/apk" "$fake_bin/apk"
  chmod +x "$fake_bin/apk"
  STUB_LOG="$(mktemp)"

  run env PATH="$fake_bin" DB_OPS_TEST=1 STUB_LOG="$STUB_LOG" sh -c ". '$SCRIPT'; ensure_dependencies"

  [ "$status" -eq 0 ]
  grep -q "apk add --no-cache mariadb-client mariadb-connector-c gzip gawk" "$STUB_LOG"
  [ -x "$fake_bin/mysql" ]
  rm -rf "$fake_bin" "$STUB_LOG"
}
```

- [ ] **步骤 5：实现 `my-ops.sh`（脚手架 + common 部分）**

创建 `my-ops.sh`：

```sh
#!/bin/sh
# my-ops.sh - single-file MySQL backup/restore tool for bare Alpine.
set -eu

# ===================== Config defaults =====================
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

# ===================== Generic helpers =====================
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

# ===================== Dependency management =====================
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

# ===================== Connection helpers =====================

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
    "--ssl" \
    "--skip-ssl-verify-server-cert"
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

# ===================== usage & main (placeholder, extended in later tasks) =====================
usage() {
  cat <<'EOF'
Usage: my-ops.sh <command> [options]

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

if [ "${DB_OPS_TEST:-0}" != "1" ]; then
  main "$@"
fi
```

运行：`chmod +x my-ops.sh`

- [ ] **步骤 6：运行测试，确认其通过**

运行：`bats tests/unit/common.bats`
预期：所有测试通过。

- [ ] **步骤 7：提交**

```bash
git add my-ops.sh tests/unit/common.bats tests/unit/stubs
git commit -m "feat: add single-file scaffolding with config parsing and connection helpers"
```

---

### 任务 2：`info` 与 `backup` 子命令（含 `--dir` 自定义备份路径）

> 本任务及任务 3 暂不依赖 Docker（Docker 集成测试环境被安排在任务 4，先完成脚本本身的开发）。测试改用 stub（桩程序）在无真实数据库的情况下验证 `my-ops.sh` 的逻辑走线是否正确；任务 5 会用任务 4 搭建的真实 MySQL 环境做端到端验证。

**文件：**
- 修改：`my-ops.sh`（新增 `cmd_info`、`cmd_backup`、`backup_one_database`，并扩展 `main` 的 `case` 分支）
- 创建：`tests/unit/info_backup.bats`
- 创建：`tests/unit/stubs/query_aware/mysql`
- 创建：`tests/unit/stubs/query_aware/mysqladmin`
- 创建：`tests/unit/stubs/query_aware/mysqldump`

**接口：**
- 消费：任务 1 的 `ensure_dependencies`、`check_connection`、`list_all_databases`、`split_csv`、`die`、`db_mysql`、`db_mysqldump`、`$BACKUP_DIR`
- 产出：`cmd_info`（由 `main` 的 `info` 分支调用）；`cmd_backup` / `backup_one_database "$db" "$out_file"`（由 `main` 的 `backup` 分支调用）
- **新增需求（相对原设计的调整）：** `backup` 支持 `--dir <path>` 指定备份存放的基础目录——若提供 `--dir`，本次备份生成的 `backup_<timestamp>/` 目录会创建在 `<path>` 下（即 `<path>/backup_<timestamp>/<db>.sql.gz`）；若不提供，则沿用默认行为，在当前工作目录下创建 `backup_<timestamp>/`。`--dir` 复用任务 1 已经解析好的 `$BACKUP_DIR` 变量（`restore` 场景下 `$BACKUP_DIR` 表示"要读取的具体备份目录"，`backup` 场景下表示"存放新备份目录的基础路径"——两种子命令对同一个变量的语义不同，但都叫 `--dir`，这是有意为之的复用，不需要新增参数名）。

- [ ] **步骤 1：编写查询感知的 stub 程序（供本任务和任务3共用）**

创建 `tests/unit/stubs/query_aware/mysql`：
```sh
#!/bin/sh
# Query-aware mysql stub: inspects "$*" for known query substrings and
# returns canned output, so cmd_info/cmd_backup/cmd_restore logic can be
# exercised without a real database. Every call is also logged to
# $STUB_LOG for assertions on which queries/flags were actually issued.
echo "$0 $*" >> "${STUB_LOG:-/dev/null}"
args="$*"
case "$args" in
  *"SCHEMA_NAME NOT IN"*) printf 'db_one\ndb_two\n'; exit 0 ;;
  *"TABLE_TYPE='BASE TABLE'"*) echo 3; exit 0 ;;
  *"TABLE_TYPE='VIEW'"*) echo 1; exit 0 ;;
  *"information_schema.ROUTINES"*) echo 2; exit 0 ;;
  *"information_schema.TRIGGERS"*) echo 1; exit 0 ;;
  *"information_schema.EVENTS"*) echo 1; exit 0 ;;
  *"GENERATION_EXPRESSION"*)
    printf '%s\n' "${MYSQL_GENCOL_RESPONSE:-}"
    exit 0
    ;;
  *)
    # DROP/CREATE DATABASE, ALTER TABLE, or schema/data import via stdin:
    # just drain stdin (if any) and succeed.
    cat >/dev/null 2>&1 || true
    exit 0
    ;;
esac
```

创建 `tests/unit/stubs/query_aware/mysqladmin`：
```sh
#!/bin/sh
echo "$0 $*" >> "${STUB_LOG:-/dev/null}"
exit "${MYSQLADMIN_EXIT_CODE:-0}"
```

创建 `tests/unit/stubs/query_aware/mysqldump`：
```sh
#!/bin/sh
# Query-aware mysqldump stub: emits a distinguishable marker line depending
# on whether it was invoked for the schema-only pass or the data-only pass,
# and includes the target database name so per-database output can be
# told apart in multi-database tests.
echo "$0 $*" >> "${STUB_LOG:-/dev/null}"
db="$(eval echo \${$#})"
case "$*" in
  *--no-data*) echo "-- SCHEMA MARKER db=${db}" ;;
  *--no-create-info*) echo "-- DATA MARKER db=${db}" ;;
  *) echo "-- UNKNOWN DUMP CALL db=${db}: $*" ;;
esac
exit 0
```

运行：`chmod +x tests/unit/stubs/query_aware/mysql tests/unit/stubs/query_aware/mysqladmin tests/unit/stubs/query_aware/mysqldump`

- [ ] **步骤 2：编写会失败的单元测试**

创建 `tests/unit/info_backup.bats`：

```bash
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

run_my_ops() {
  ( cd "$WORK_DIR" && env PATH="$STUB_DIR:$PATH" STUB_LOG="$STUB_LOG" "$@" "$SCRIPT" \
      --host h --port 3306 --user u --password p )
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
```

- [ ] **步骤 3：运行测试，确认其失败**

运行：`bats tests/unit/info_backup.bats`
预期：失败 —— `info`/`backup` 尚未在 `main` 的 `case` 中接入，会命中 "Unknown command"。

- [ ] **步骤 4：在 `my-ops.sh` 中实现 `cmd_info`、`cmd_backup`、`backup_one_database`**

在 `my-ops.sh` 的 `usage()` 函数之前插入：

```sh
# ===================== info subcommand =====================
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

# ===================== backup subcommand =====================
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
  if [ -n "$BACKUP_DIR" ]; then
    [ -d "$BACKUP_DIR" ] || die "Backup base directory not found: $BACKUP_DIR"
    out_dir="${BACKUP_DIR%/}/backup_${timestamp}"
  else
    out_dir="backup_${timestamp}"
  fi
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

并在 `main` 的 `case "$cmd" in` 中，`-h|--help|help)` 分支之前加入：

```sh
    info)
      cmd_info
      ;;
    backup)
      cmd_backup
      ;;
```

同时更新 `usage()` 中 backup 选项一节，补充 `--dir` 的说明：

```
backup options:
  --database <db1,db2>  Comma-separated list of databases to back up
  --all-databases        Back up all non-system databases
  --dir <path>           Base directory to place the timestamped backup_<ts>/
                         folder in (default: current directory)
```

- [ ] **步骤 5：运行测试，确认其通过**

运行：`bats tests/unit/info_backup.bats`
预期：全部通过。

- [ ] **步骤 6：连带回归旧测试**

运行：`bats tests/unit/common.bats`
预期：任务 1 的全部测试依旧通过（本任务未修改 `main()` 中已有的顺序逻辑，只新增了 `case` 分支和两个新函数）。

- [ ] **步骤 7：提交**

```bash
git add my-ops.sh tests/unit/info_backup.bats tests/unit/stubs/query_aware
git commit -m "feat: add info and backup subcommands with --dir support"
```

---

### 任务 3：`restore` 子命令（含生成列安全处理）

**文件：**
- 修改：`my-ops.sh`（新增 `GENCOL_AWK_PROGRAM`、`cmd_restore`、`restore_one_database`，扩展 `main` 的 `case` 分支）
- 创建：`tests/unit/gencol_filter.bats`
- 创建：`tests/unit/restore.bats`

**接口：**
- 消费：任务 1 的 `ensure_dependencies`、`check_connection`、`split_csv`、`confirm`、`die`、`db_mysql`；任务 2 的查询感知 stub（`tests/unit/stubs/query_aware/*`）与产出的备份文件格式
- 产出：`GENCOL_AWK_PROGRAM`（shell 变量，内嵌 awk 程序文本，接受 `-v mapfile=<table\tcolumn 映射文件>`，重写匹配的 `INSERT INTO \`table\` (...) VALUES` 语句的列名列表，为映射中列出的生成列名追加 `_tmp`，不改动 VALUES 部分）；`cmd_restore`（由 `main` 的 `restore` 分支调用）；`restore_one_database "$db" "$archive"`（DROP/CREATE → 导入 schema → 为生成列新增 `_tmp` 暂存列 → 用 `GENCOL_AWK_PROGRAM` 过滤 data 部分 → 导入 → 删除 `_tmp` 列）

- [ ] **步骤 1：为 awk 过滤程序编写会失败的单元测试**

创建 `tests/unit/gencol_filter.bats`：

```bash
#!/usr/bin/env bats

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../../my-ops.sh"
  export DB_OPS_TEST=1
  # shellcheck disable=SC1090
  . "$SCRIPT"
}

@test "GENCOL_AWK_PROGRAM rewrites only the generated column in the column list, not VALUES" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `products` (`id`, `name`, `price`, `price_with_tax`, `name_upper`, `thumbnail`) VALUES (1,'Widget',9.99,10.99,'WIDGET',0x89504E47);
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'price_with_tax mentioned here, not a real column');
EOF
  printf 'products\tprice_with_tax\nproducts\tname_upper\n' > "$map_file"

  run gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql"
  [ "$status" -eq 0 ]

  [[ "$output" == *'`products` (`id`, `name`, `price`, `price_with_tax_tmp`, `name_upper_tmp`, `thumbnail`) VALUES (1,'"'"'Widget'"'"',9.99,10.99,'"'"'WIDGET'"'"',0x89504E47)'* ]]
  [[ "$output" == *"price_with_tax mentioned here, not a real column"* ]]

  rm -f "$data_sql" "$map_file"
}

@test "GENCOL_AWK_PROGRAM leaves tables with no generated columns untouched" {
  data_sql="$(mktemp)"
  map_file="$(mktemp)"
  cat > "$data_sql" <<'EOF'
INSERT INTO `audit_log` (`id`, `message`) VALUES (1,'hello');
EOF
  : > "$map_file"

  run gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql"
  [ "$status" -eq 0 ]
  [ "$output" = "INSERT INTO \`audit_log\` (\`id\`, \`message\`) VALUES (1,'hello');" ]

  rm -f "$data_sql" "$map_file"
}
```

- [ ] **步骤 2：运行测试，确认其失败**

运行：`bats tests/unit/gencol_filter.bats`
预期：失败 —— `$GENCOL_AWK_PROGRAM` 尚未定义。

- [ ] **步骤 3：编写会失败的 stub 化 restore 单元测试**

创建 `tests/unit/restore.bats`：

```bash
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
  run_restore run "$SCRIPT" restore --host h --port 3306 --user u --password p --database plaindb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --dir"* ]]
}

@test "restore requires an explicit --database" {
  run_restore run "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Specify --database"* ]]
}

@test "restore dies when the backup file for a database is missing" {
  run_restore run "$SCRIPT" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database nosuchdb --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"Backup file not found"* ]]
}

@test "restore aborts without --force when the user declines confirmation" {
  run_restore bash -c "echo n | \"$SCRIPT\" restore --host h --port 3306 --user u --password p --dir backup_20260101_000000 --database plaindb"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Aborted by user"* ]]
}

@test "restore imports a database with no generated columns" {
  run_restore env MYSQL_GENCOL_RESPONSE="" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database plaindb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: plaindb"* ]]
  grep -q "DROP DATABASE IF EXISTS \`plaindb\`" "$STUB_LOG"
  grep -q "CREATE DATABASE \`plaindb\`" "$STUB_LOG"
  ! grep -q "_tmp" "$STUB_LOG"
}

@test "restore stages generated columns through _tmp and cleans them up" {
  run_restore env MYSQL_GENCOL_RESPONSE="$(printf 'products\tprice_with_tax\tdecimal(10,2)\nproducts\tname_upper\tvarchar(100)')" \
    "$SCRIPT" restore --host h --port 3306 --user u --password p \
    --dir backup_20260101_000000 --database gencoldb --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restored database: gencoldb"* ]]
  grep -q "ADD COLUMN \`price_with_tax_tmp\` decimal(10,2)" "$STUB_LOG"
  grep -q "ADD COLUMN \`name_upper_tmp\` varchar(100)" "$STUB_LOG"
  grep -q "DROP COLUMN \`price_with_tax_tmp\`" "$STUB_LOG"
  grep -q "DROP COLUMN \`name_upper_tmp\`" "$STUB_LOG"
}
```

- [ ] **步骤 4：运行测试，确认其失败**

运行：`bats tests/unit/restore.bats`
预期：失败 —— `restore` 尚未在 `main` 的 `case` 中接入。

- [ ] **步骤 5：在 `my-ops.sh` 中实现生成列过滤程序与 `cmd_restore`、`restore_one_database`**

在 `my-ops.sh` 的 `usage()` 函数之前插入：

```sh
# ===================== restore subcommand =====================

# Rewrites the INSERT column-name list (never the VALUES clause) so that
# generated columns (listed in `mapfile`, tab-separated "table<TAB>column")
# are redirected to <column>_tmp during data import. Invoked as:
#   gawk -v mapfile=<path> "$GENCOL_AWK_PROGRAM" data.sql
GENCOL_AWK_PROGRAM='
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
'

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
    gawk -v mapfile="$map_file" "$GENCOL_AWK_PROGRAM" "$data_sql" > "$filtered_data_sql"
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

并在 `main` 的 `case "$cmd" in` 中，`-h|--help|help)` 分支之前加入：

```sh
    restore)
      cmd_restore
      ;;
```

- [ ] **步骤 6：运行测试，确认其通过**

运行：`bats tests/unit/gencol_filter.bats tests/unit/restore.bats`
预期：全部通过。

- [ ] **步骤 7：连带回归旧测试**

运行：`bats tests/unit/common.bats tests/unit/info_backup.bats`
预期：任务 1、2 的全部测试依旧通过。

- [ ] **步骤 8：提交**

```bash
git add my-ops.sh tests/unit/gencol_filter.bats tests/unit/restore.bats
git commit -m "feat: add restore subcommand with generated-column-safe staging"
```

---

### 任务 4：集成测试环境（Docker + 自签名 TLS MySQL）

**文件：**
- 创建：`tests/integration/docker-compose.yml`
- 创建：`tests/integration/init.sql`

**接口：**
- 产出：一个运行中的 `mysql:8` 容器（服务名 `mysql`，网络 `db-ops-test-net`，数据库 `testdb`，root 密码 `rootpass`），首次启动时自动生成自签名 TLS 证书，并预置一套覆盖以下内容的 schema：一个带 `VIRTUAL` 生成列的表、一个带 `STORED` 生成列的表、一个 `BLOB` 字段、一个视图、一个存储过程、一个触发器和一个事件。任务 5 通过 `docker run --network db-ops-test-net -v <repo>:/work -w /work alpine:latest sh -c "./my-ops.sh ..."` 连接它，证明单文件工具能在裸 Alpine 上运行。

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
    image: mysql:8
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: testdb
    ports:
      - "3307:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-uroot", "-prootpass"]
      interval: 5s
      timeout: 5s
      retries: 20
```

> **注意（实际执行中发现）：** 最初设计里 `init.sql` 通过 bind mount 挂载到
> `/docker-entrypoint-initdb.d/init.sql` 由容器首次启动时自动执行。但在本机
> Rancher Desktop 的 virtiofs 文件共享上，单文件 bind mount 会导致容器内报
> `ERROR: Can't initialize batch_readline - may be the input source is a
> directory or a block device`（源文件在宿主机上确实是普通文件，但通过
> virtiofs 挂载后容器内一度识别异常）。因此 compose 文件里**不再**挂载
> `init.sql`，改为容器启动健康后，手动把 `init.sql` 管道给容器内的
> `mysql` 客户端执行（见步骤 3）。这一问题是否在其他 Docker/Rancher
> Desktop 版本或 Linux 宿主机上复现未知，如果你的环境 bind mount 正常，
> 也可以按原设计挂载，二者效果等价。

- [ ] **步骤 3：启动环境、灌入种子数据并手动验证**

运行：
```bash
cd tests/integration
docker compose up -d --wait
```
预期：命令退出码为 0，`docker compose ps` 显示 `mysql` 状态为 `healthy`。

灌入种子 schema（健康检查通过后，`docker-entrypoint-initdb.d` 不再自动执行，
需要手动执行一次）：
```bash
docker compose exec -T mysql mysql -uroot -prootpass testdb < init.sql
```

- [ ] **步骤 4：从裸 Alpine 容器验证自签名 TLS 与种子 schema**

> **注意（实际执行中发现）：** 本机同样发现 virtiofs 对宿主机目录的 bind
> mount（`docker run -v <host目录>:/work ...`）存在缓存滞后问题，容器内
> 可能看到过期/缺文件的快照。验证时改用 `docker cp` 把需要的文件拷进一个
> 长期存活的容器，而不是 bind mount；如果你的环境 bind mount 正常，也可以
> 直接用 `-v` 挂载。

运行（若 Alpine 官方 CDN 在你的网络下证书校验失败/不可达，替换成国内镜像源，
如下示例已包含该替换，正常网络环境可以去掉这行 `sed`）：
```bash
docker run --rm --network db-ops-test-net alpine:latest sh -c "
  sed -i 's/dl-cdn.alpinelinux.org/mirrors.aliyun.com/g' /etc/apk/repositories
  apk add --no-cache mariadb-client mariadb-connector-c >/dev/null &&
  mysql --ssl --skip-ssl-verify-server-cert \
    -h mysql -P 3306 -uroot -prootpass testdb \
    -e 'SHOW TABLES; SELECT COUNT(*) FROM products;'
"
```
预期：打印表清单（`audit_log`、`products`）以及行数 `3`，没有 TLS 证书相关错误。

- [ ] **步骤 5：验证完毕后清理环境**

运行：
```bash
cd tests/integration
docker compose down -v
```
预期：容器和匿名卷被清理，不留常驻容器（任务 5 的测试会自行启动/停止）。

- [ ] **步骤 6：提交**

```bash
git add tests/integration/docker-compose.yml tests/integration/init.sql
git commit -m "test: add dockerized MySQL integration environment with self-signed TLS"
```

---

### 任务 5：全流程端到端验证与使用文档

**文件：**
- 创建：`tests/integration/full_roundtrip.bats`
- 创建：`README.md`

**接口：**
- 消费：任务 2–3 的 `cmd_info`、`cmd_backup`、`cmd_restore`；任务 4 的 Docker 环境
- 产出：一份文档完善、经过完整验证的单文件 CLI（本任务不新增共享接口，仅做验证与文档）

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
    alpine:latest sh -c "$1"
}

query_testdb() {
  run_in_alpine "apk add --no-cache mariadb-client >/dev/null && mysql --ssl --skip-ssl-verify-server-cert -h mysql -P 3306 -uroot -prootpass -N -B -e \"$1\" testdb"
}

@test "end to end: info, backup, restore reproduce all object types and data" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./my-ops.sh info --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run query_testdb "DROP DATABASE testdb;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
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

@test "end to end: generated columns and blobs round-trip, --dir works, no _tmp columns remain" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_* "$root"/custom_backups

  run query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"
  before_output="$output"

  mkdir -p "$root/custom_backups"
  run run_in_alpine "./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb --dir custom_backups"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/custom_backups/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run query_testdb "DROP TABLE IF EXISTS products;"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT id, price_with_tax, name_upper, HEX(thumbnail) FROM products ORDER BY id;"
  [ "$status" -eq 0 ]
  [ "$output" = "$before_output" ]

  run query_testdb "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='testdb' AND COLUMN_NAME LIKE '%_tmp';"
  [ "$output" = "0" ]

  rm -rf "$root/custom_backups"
}

@test "restore is idempotent when run twice against the same backup" {
  root="$BATS_TEST_DIRNAME/../.."
  rm -rf "$root"/backup_*

  run run_in_alpine "./my-ops.sh backup --host mysql --port 3306 --user root --password rootpass --database testdb"
  [ "$status" -eq 0 ]
  backup_dir="$(ls -d "$root"/backup_* | tail -1)"
  rel_backup_dir="${backup_dir#$root/}"

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run run_in_alpine "./my-ops.sh restore --host mysql --port 3306 --user root --password rootpass --dir '${rel_backup_dir}' --database testdb --force"
  [ "$status" -eq 0 ]

  run query_testdb "SELECT COUNT(*) FROM products;"
  [ "$output" = "3" ]

  rm -rf "$backup_dir"
}
```

- [ ] **步骤 2：运行测试，确认其通过**

运行：`bats tests/integration/full_roundtrip.bats`
预期：全部通过（本测试组合了任务 2–3 已实现的行为；若有断言失败，应先修复 `my-ops.sh`，而不是弱化测试断言）。

- [ ] **步骤 3：编写 `README.md`**

创建 `README.md`：

```markdown
# my-ops

一个单一文件的 POSIX shell 工具（`my-ops.sh`），用于在裸 Alpine 环境下备份和
恢复 MySQL 数据库，连接时信任自签名 TLS 证书，并正确处理生成（虚拟/存储）列
和 BLOB 数据。

## 环境要求

可在任何具备 `apk` 且能网络访问目标 MySQL 服务器的 Alpine 容器中运行。
只需要这一个文件（`my-ops.sh`），所有依赖
（`mariadb-client`、`mariadb-connector-c`、`gzip`、`gawk`）首次运行时自动安装。

## 用法

\`\`\`sh
# 检查连通性并查看将被备份的内容
./my-ops.sh info --host mysql --port 3306 --user root --password secret --database mydb

# 备份一个或多个数据库（默认在当前目录生成 backup_<timestamp>/<db>.sql.gz）
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database db1,db2
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --all-databases

# 用 --dir 指定备份存放的基础目录（会在该目录下创建 backup_<timestamp>/）
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb --dir /srv/backups

# 从备份目录恢复一个或多个数据库（破坏性操作：DROP + CREATE）
./my-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb
./my-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup_20260819_120000 --database mydb --force
\`\`\`

注意：`--dir` 在 `backup` 和 `restore` 中的含义不同——`backup` 场景下它是
"存放新备份目录的基础路径"，`restore` 场景下它是"要读取的具体备份目录"。

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
./my-ops.sh info --config db.conf --database mydb
\`\`\`

命令行参数始终会覆盖配置文件中的同名值。建议通过 `DB_PASSWORD` 环境变量传递密码，
而不是 `--password` 参数或配置文件，以避免密码留存在 shell 历史或磁盘上。

## TLS

所有连接均使用 `--ssl --skip-ssl-verify-server-cert`：
流量被加密，但不校验服务器证书，因此自签名证书无需额外配置即可正常工作。

## 生成列

备份时 `CREATE TABLE` 语句始终包含完整的列定义。恢复时，生成（虚拟/存储）列本身
绝不会被直接修改：会新增一个 `<column>_tmp` 列临时接收 dump 出来的值，待数据库
根据同一行的其他数据重新计算出真正的生成列后，再删除该临时列。这意味着表上的
索引、唯一约束、外键都不会受到任何影响。

## 运行测试

单元测试（无需数据库，用 stub 验证逻辑走线）：

\`\`\`sh
brew install bats-core   # 一次性安装，macOS
bats tests/unit
\`\`\`

集成测试（需要 Docker，启动真实 MySQL 验证端到端行为）：

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

- **需求覆盖：** 单文件交付（全部任务，脚本名 `my-ops.sh`）、apk 自动安装（任务 1）、自签名 TLS 且不校验证书（任务 1）、完整 DDL+DML 含视图/存储过程/触发器/事件（任务 2、5）、hex-blob 二进制数据安全性（任务 2，任务 5 中验证）、生成列安全恢复且不影响索引（任务 3）、多库 + `--all-databases`（任务 2）、带时间戳目录且每库一个文件、`--dir` 自定义备份基础路径（任务 2，任务 5 中验证）、恢复必须显式指定 `--database` 且需确认/支持 `--force`（任务 3）、`info` 子命令（任务 2）——均已覆盖。开发顺序调整为"先完成脚本本身（任务2、3用 stub 验证），再搭建 Docker 环境（任务4），最后端到端验证（任务5）"，是应人类要求做的调整，不影响最终交付的完整性。
- **占位符检查：** 无 TBD/TODO 标记；每个步骤都有可运行的代码。
- **命名/类型一致性：** `cmd_info`/`cmd_backup`/`cmd_restore` 均由同一个 `main` 函数的 `case` 分发；`backup_one_database`/`restore_one_database` 签名在任务 2–3 中保持一致；`GENCOL_AWK_PROGRAM` 的 `mapfile` 格式（`table\tcolumn`）与任务 3 步骤 5 中 `restore_one_database` 写入的格式一致；`DB_OPS_TEST` 守卫在任务 1 引入后被任务 3 的单元测试沿用；`$BACKUP_DIR` 在任务 1 中定义、任务 2（backup 语义）与任务 3（restore 语义）中复用，语义差异已在任务 2 接口说明中明确标注。
