# PostgreSQL 备份恢复工具设计文档（pg-ops.sh）

## 目标

`my-ops.sh`（MySQL/MariaDB）的姊妹工具，同样是在裸 Alpine 环境下运行的单个
shell 脚本，支持对 PostgreSQL 数据库（含所有用户表、视图、函数、触发器、
序列）进行完整 DDL+DML 备份与恢复，兼容自签名 TLS 证书，正确处理生成列。

整体架构、CLI 参数、`dbs.conf` 配置格式与 `my-ops.sh` 保持高度对称——本文档
只记录 **与 `my-ops.sh` 不同** 的关键设计决策；未提及的部分（INI 解析、
`--config`/`--instance` 解析流程、`confirm()` 的 `/dev/tty` 读取、
`validate_identifier`/`sanitize_path_component` 的允许字符集、
`register_tmp_file`/`cleanup_common` 的临时文件清理机制等）与 `my-ops.sh`
完全一致，详见
`docs/superpowers/specs/2026-08-19-mysql-backup-restore-design.md`。

## 单文件独立分发

`pg-ops.sh` 不 `source` `my-ops.sh`，也不依赖任何共享 lib 文件；两者需要的
INI 解析等通用逻辑是刻意复制粘贴到两个文件里的（可接受的代码重复），以保证
每个脚本都能单独复制到目标机器上运行。

## 依赖（启动时自动 apk 安装）

- `postgresql-client`（提供 `psql` / `pg_dump` / `pg_isready` 等）
- `gzip`

**不需要 `gawk`**：`my-ops.sh` 需要 `gawk` 是为了在恢复生成列时重写 INSERT
语句的列名（配合 `__tmp` 暂存列）。`pg-ops.sh` 完全没有这个需求（见下文
"生成列处理"），因此依赖集合更小。

## 密码传递：临时 .pgpass 文件

不通过命令行参数或 `PGPASSWORD` 环境变量传递密码（两者都可能被同主机其他
进程通过 `/proc/<pid>/cmdline`、`/proc/<pid>/environ` 等方式窥探到）。改为
生成一个临时的 `.pgpass` 格式文件：

```
hostname:port:database:username:password
```

`database` 字段固定使用通配符 `*`（因为同一个连接凭证在恢复流程中要先后
连接 `postgres` 维护库和目标库两个不同的数据库名），并设置 `PGPASSFILE`
环境变量指向它，`chmod 600`，通过与 `my-ops.sh` 相同的
`register_tmp_file`/`cleanup_common` 机制在退出时（含异常退出）清理。

同时传入 `--no-password`，禁止 `psql`/`pg_dump` 在密码文件缺失或不匹配时
退化为交互式密码提示——快速失败，而不是在无人值守场景里悬挂等待输入。

## TLS

通过环境变量 `PGSSLMODE=require` 传给所有 `psql`/`pg_dump` 调用。libpq 的
`require` 模式本身就是"加密传输，但不校验服务器证书"，语义上等价于
`my-ops.sh` 的 `--ssl --skip-ssl-verify-server-cert`，不需要像 MySQL 那样
额外传一个"跳过校验"的参数。

**重要**：PostgreSQL 官方/pgvector 镜像默认不开启 TLS（`SHOW ssl;` 报告
`off`）。经实测验证，需要在容器内生成自签名证书并在 `postgresql.conf` 里
设置 `ssl = on` + `ssl_cert_file`/`ssl_key_file` 才能开启（见集成测试
`tests/integration/pg_full_roundtrip.bats` 的 `setup_file`）。

## 备份：单次 pg_dump 即可

`my-ops.sh` 因 mariadb-dump 对 `--routines` 的已知 bug（`SHOW PACKAGE
STATUS` 探测在纯 MySQL 服务器上报语法错误）需要拆分 schema-only 和
data-only 两次 dump，并在 schema dump 失败时做降级重试。

`pg_dump` 没有这个问题：其默认纯文本输出本身就是完整、自洽的单个文件
（表结构 + 数据 + 视图 + 函数 + 触发器 + 序列的 DDL 全部包含），因此
`pg-ops.sh` 的 `backup_one_database` 只需一次 `pg_dump` 调用，比
`my-ops.sh` 简单得多。

## 恢复：两阶段连接（关键差异）

PostgreSQL **不允许 DROP 一个连接当前正在使用的数据库**。这与 MySQL 不同
（`my-ops.sh` 可以在目标数据库所在的同一个连接上直接执行 `DROP DATABASE`
+ `CREATE DATABASE`）。因此 `restore_one_database` 必须是两阶段连接：

1. 连接到维护数据库 `postgres`（而不是目标库本身），在这个连接上执行
   `DROP DATABASE IF EXISTS "<db>";` 和 `CREATE DATABASE "<db>";`。
2. 断开该维护库连接。
3. 重新建立一个连接到刚创建好的目标数据库 `<db>`。
4. 用这个新连接把解压后的 dump 内容通过 `psql -f <file>` 导入。

单元测试（`tests/unit/pg_restore.bats`）通过检查 stub 记录的
`--dbname=postgres` 与 `--dbname=<db>` 调用顺序验证了这个两阶段逻辑确实
生效；集成测试进一步验证了真实 PostgreSQL 服务器上这一流程能够成功重建
数据库。

## 生成列处理：无需暂存列（关键差异）

`my-ops.sh` 恢复 MySQL 生成列（`GENERATED ALWAYS AS (...) VIRTUAL/STORED`）
时，因为 `mysqldump` 的 `INSERT` 语句会包含生成列的值（即使该值本应由数据库
重新计算），需要：

1. 恢复前查询 `information_schema.COLUMNS` 找出所有生成列；
2. 为每个生成列临时增加一个 `<column>__tmp` 列；
3. 用 `gawk` 重写 INSERT 语句的列名列表，把目标列名替换为 `<column>__tmp`；
4. 导入数据（写入 `__tmp` 列，真正的生成列还是走数据库自己的计算逻辑，不受
   导入数据干扰）；
5. 删除所有 `__tmp` 暂存列。

PostgreSQL 的 `pg_dump` 完全不需要这套流程：其 `COPY`/`INSERT` 数据输出
天然就不包含生成列的值（PostgreSQL 服务器在 dump 时就已经排除了它们），
而 `CREATE TABLE` 语句里仍然完整保留 `GENERATED ALWAYS AS (...) STORED`
定义。因此恢复时只需把 dump 文件整体、原样导入（`psql -f dumpfile`），
PostgreSQL 会在插入每一行时根据该行的其他列自动重新计算生成列的值——不需要
任何暂存列、列名重写或额外的 ALTER TABLE 步骤。

这一点已通过集成测试验证：恢复后 `products.price_with_tax`（
`GENERATED ALWAYS AS (price * 1.1) STORED`）的值与恢复前完全一致，且整个
过程日志中不出现任何 `ADD COLUMN`/`DROP COLUMN`/`__tmp` 相关操作。

## 对象概览字段差异

PostgreSQL 没有内置的事件调度器（对应 `my-ops.sh` `info` 命令里的 Events
计数），`pg-ops.sh` 改为报告 Sequences（序列）计数，通过 `pg_sequences`
系统视图查询。函数计数通过 `pg_proc` + `pg_namespace` 联表查询
`public` schema 下的函数（PostgreSQL 没有 MySQL 那样区分存储过程/函数的
`ROUTINE_TYPE` 需求，`pg_proc` 统一处理）。

## 恢复范围限制

与 `my-ops.sh` 完全一致：`restore` 不支持 `--all-databases`，必须显式指定
`--database <db1,db2>` 列表；这是一项刻意的安全设计，防止误操作导致大范围
数据丢失。
