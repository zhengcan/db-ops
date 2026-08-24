# db-ops

本仓库包含两个姊妹工具，均为单一文件的 POSIX shell 脚本，架构、CLI、
`dbs.conf` 配置格式高度对称：

- **`my-ops.sh`** —— MySQL/MariaDB 备份/恢复工具
- **`pg-ops.sh`** —— PostgreSQL 备份/恢复工具

两者都可在裸 Alpine 环境下运行，连接时信任自签名 TLS 证书，正确处理生成
（虚拟/存储）列和二进制数据，且都是完全独立、可单独复制分发的单文件脚本
（不互相 `source`，不依赖共享 lib 文件）。

## my-ops.sh（MySQL/MariaDB）

用于在裸 Alpine 环境下备份和恢复 MySQL 数据库，连接时信任自签名 TLS 证书，
并正确处理生成（虚拟/存储）列和 BLOB 数据。

## 环境要求

可在任何具备 `apk` 且能网络访问目标 MySQL 服务器的 Alpine 容器中运行。
只需要这一个文件（`my-ops.sh`），所有依赖
（`mariadb-client`、`mariadb-connector-c`、`gzip`、`gawk`）首次运行时自动安装。

## 用法

```sh
# 检查连通性并查看将被备份的内容
./my-ops.sh info --host mysql --port 3306 --user root --password secret --database mydb

# 备份一个或多个数据库（默认在当前目录生成 backup/mysql/<label>/<timestamp>/<db>.sql.gz，
# 其中 <label> 是：若通过 dbs.conf/--instance 使用了配置实例，则为该实例名；
# 否则为 --host/DB_HOST 经清洗后的值（仅保留字母、数字、'.'、'-'、'_'））
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database db1,db2
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --all-databases

# 用 --dir 指定备份存放的基础目录（会在该目录下创建 backup_<timestamp>/，行为不变）
./my-ops.sh backup --host mysql --port 3306 --user root --password secret --database mydb --dir /srv/backups

# 从备份目录恢复一个或多个数据库（破坏性操作：DROP + CREATE）
./my-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup/mysql/mysql/20260819_120000 --database mydb
./my-ops.sh restore --host mysql --port 3306 --user root --password secret \
  --dir backup/mysql/mysql/20260819_120000 --database mydb --force
```

注意：`--dir` 在 `backup` 和 `restore` 中的含义不同——`backup` 场景下它是
"存放新备份目录的基础路径"，`restore` 场景下它是"要读取的具体备份目录"。

## 配置文件

除了传参，也可以使用 INI 风格的多实例配置文件，默认文件名 `dbs.conf`：

```ini
# dbs.conf
[prod]
type = mysql
host = mysql.example.internal
port = 3306
user = backup_user
password = secret
database = mydb

[staging]
type = mysql
host = staging.example.internal
port = 3306
user = backup_user
password = secret
```

- 当前目录下存在 `dbs.conf` 且未显式传 `--config` 时，会自动加载它；不存在时完全不
  影响现有纯命令行/环境变量用法。
- 也可以用 `--config <path>` 显式指定其他路径的配置文件（同样的格式）。
- 配置文件里只定义了 **1 个** 实例时，会自动选用它，无需再传 `--instance`。
- 配置文件里定义了 **2 个及以上** 实例时，必须通过 `--instance <名字>` 指定使用哪个，
  否则会报错并列出所有可选实例名。
- 每个实例段落里的 `type` 字段必须是 `mysql`（大小写不敏感），否则会报错——本工具
  目前只支持 MySQL/MariaDB 实例。

```sh
# 只有一个实例时，自动选用
./my-ops.sh info --database mydb

# 显式指定配置文件路径与实例名
./my-ops.sh info --config dbs.conf --instance prod --database mydb
```

命令行参数（`--host`/`--port`/`--user`/`--password`/`--database` 等）始终会覆盖配置
实例中的同名字段。建议通过 `DB_PASSWORD` 环境变量传递密码，而不是 `--password` 参数
或配置文件，以避免密码留存在 shell 历史或磁盘上。

`dbs.conf` 是纯文本格式，按 `key = value` 逐行解析（不需要引号包裹值），不会被当作
可执行 shell 代码 `source`，因此不存在旧版本中"配置文件等同任意可执行 shell 代码"的
风险。

## TLS

所有连接均使用 `--ssl --skip-ssl-verify-server-cert`：
流量被加密，但不校验服务器证书，因此自签名证书无需额外配置即可正常工作。

## 生成列

备份时 `CREATE TABLE` 语句始终包含完整的列定义。恢复时，生成（虚拟/存储）列本身
绝不会被直接修改：会新增一个 `<column>__tmp` 列临时接收 dump 出来的值，待数据库
根据同一行的其他数据重新计算出真正的生成列后，再删除该临时列。这意味着表上的
索引、唯一约束、外键都不会受到任何影响。

## 运行测试

单元测试（无需数据库，用 stub 验证逻辑走线；包含 `my-ops.sh` 和 `pg-ops.sh`
两者的测试）：

```sh
brew install bats-core   # 一次性安装，macOS
bats tests/unit
```

集成测试（需要 Docker）：

```sh
bats tests/integration/full_roundtrip.bats     # my-ops.sh，启动真实 MySQL
bats tests/integration/pg_full_roundtrip.bats  # pg-ops.sh，启动真实 PostgreSQL
```

---

## pg-ops.sh（PostgreSQL）

`my-ops.sh` 的姊妹工具，架构、CLI 参数、`dbs.conf` 配置格式完全对称，面向
PostgreSQL。同样是单一文件、可独立分发，不依赖 `my-ops.sh` 或任何共享 lib
文件。

### 环境要求

可在任何具备 `apk` 且能网络访问目标 PostgreSQL 服务器的 Alpine 容器中运行。
只需要这一个文件（`pg-ops.sh`），所需依赖（`postgresql-client`，提供
`psql`/`pg_dump` 等；以及 `gzip`）首次运行时自动安装。与 `my-ops.sh` 不同，
`pg-ops.sh` **不需要 `gawk`**——见下文"与 my-ops.sh 的关键差异"。

### 用法

```sh
# 检查连通性并查看将被备份的内容（表/视图/函数/触发器/序列计数）
./pg-ops.sh info --host pg --port 5432 --user postgres --password secret --database mydb

# 备份一个或多个数据库（默认在当前目录生成 backup/pg/<label>/<timestamp>/<db>.sql.gz，
# <label> 规则与 my-ops.sh 相同：dbs.conf/--instance 实例名优先，否则用清洗后的主机名）
./pg-ops.sh backup --host pg --port 5432 --user postgres --password secret --database mydb
./pg-ops.sh backup --host pg --port 5432 --user postgres --password secret --database db1,db2
./pg-ops.sh backup --host pg --port 5432 --user postgres --password secret --all-databases

# 用 --dir 指定备份存放的基础目录
./pg-ops.sh backup --host pg --port 5432 --user postgres --password secret --database mydb --dir /srv/backups

# 从备份目录恢复一个或多个数据库（破坏性操作：DROP + CREATE DATABASE；
# 不支持 --all-databases，必须显式指定 --database）
./pg-ops.sh restore --host pg --port 5432 --user postgres --password secret \
  --dir backup/pg/pg/20260824_120000 --database mydb
./pg-ops.sh restore --host pg --port 5432 --user postgres --password secret \
  --dir backup/pg/pg/20260824_120000 --database mydb --force
```

### dbs.conf 共享

`pg-ops.sh` 读取**与 `my-ops.sh` 完全相同**的 `dbs.conf` 文件格式与发现逻辑
（当前目录自动发现、`--config`/`--instance` 用法、单实例自动选/多实例必须
指定），区别仅在于：`pg-ops.sh` 只接受 `type = pg`（大小写不敏感）的实例；
若选中的实例 `type` 是 `mysql` 或其他值，会报错拒绝。这意味着同一个
`dbs.conf` 文件可以同时描述 MySQL 和 PostgreSQL 实例，用哪个工具就自动只
认对应类型的实例：

```ini
# dbs.conf
[mysql_prod]
type = mysql
host = mysql.example.internal
port = 3306
user = backup_user
password = secret
database = mydb

[pg_prod]
type = pg
host = pg.example.internal
port = 5432
user = backup_user
password = secret
database = mydb
```

```sh
./my-ops.sh info --instance mysql_prod   # 正常工作
./pg-ops.sh  info --instance pg_prod     # 正常工作
./pg-ops.sh  info --instance mysql_prod  # 报错：type=mysql，pg-ops.sh 只支持 pg 实例
```

### TLS

所有连接通过环境变量 `PGSSLMODE=require` 传给 `psql`/`pg_dump`：这是
libpq 的"加密但不校验服务器证书"模式，效果上等同于 `my-ops.sh` 的
`--ssl --skip-ssl-verify-server-cert`，自签名证书无需额外配置即可正常
工作。

### 密码安全

不同于通过命令行参数或 `PGPASSWORD` 环境变量传递密码（可能被同主机其他
进程通过 `/proc`、`ps` 等方式窥探到），`pg-ops.sh` 会生成一个临时的
`.pgpass` 格式文件（`hostname:port:database:username:password`，
`database` 字段固定用通配符 `*`），设置 `PGPASSFILE` 指向它，`chmod 600`，
并通过与 `my-ops.sh` 相同的 `register_tmp_file`/`cleanup_common` 机制在
退出时（含异常退出）清理。

### 与 my-ops.sh 的关键差异

1. **恢复需要两阶段连接**：PostgreSQL 不允许 `DROP DATABASE` 当前连接所在
   的数据库。因此 `restore` 会先连接到维护数据库 `postgres`执行
   `DROP DATABASE IF EXISTS` + `CREATE DATABASE`，断开后再重新连接到刚创建
   好的目标数据库导入 dump 内容。`my-ops.sh` 没有这个限制，可以直接在目标
   数据库连接上执行 DROP/CREATE。
2. **生成列无需暂存列（`__tmp`）技巧**：`my-ops.sh` 恢复 MySQL 生成列时，
   需要临时增加 `<column>__tmp` 列接收 dump 出来的值，再删除临时列，因为
   `mysqldump` 的 `INSERT` 语句会包含生成列的值。PostgreSQL 的 `pg_dump`
   则完全不同：它的 `COPY`/`INSERT` 数据天然就不包含生成列的值（`CREATE
   TABLE` 里仍保留完整的 `GENERATED ALWAYS AS (...) STORED` 定义），恢复时
   数据库会自动根据同一行的其他列重新计算，因此 `pg-ops.sh` 的恢复流程里
   完全没有暂存列这一步，逻辑上更简单。
3. **单次 dump 即可**：`my-ops.sh` 因 mariadb-dump 的已知 bug 需要拆分
   schema-only 和 data-only 两次 dump。`pg_dump` 的纯文本输出本身就是完整
   自洽的单文件（结构+数据+视图+函数+触发器+序列），`pg-ops.sh` 只需一次
   `pg_dump` 调用。
4. **对象概览的字段不同**：PostgreSQL 没有内置的事件调度器（对应
   `my-ops.sh` 的 Events 计数），`pg-ops.sh` 用 Sequences（序列）计数
   替代。
5. **不需要 `gawk`**：`my-ops.sh` 用 `gawk` 重写 INSERT 语句的列名以配合
   `__tmp` 暂存列技巧；`pg-ops.sh` 没有这个需求，依赖仅为
   `postgresql-client` + `gzip`。

### 生成列

见上文"与 my-ops.sh 的关键差异"第 2 点：`pg-ops.sh` 恢复生成列时不做任何
特殊处理，直接整体导入 dump 文件即可，PostgreSQL 会自动重新计算生成列的
值。

