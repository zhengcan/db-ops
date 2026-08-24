# my-ops

一个单一文件的 POSIX shell 工具（`my-ops.sh`），用于在裸 Alpine 环境下备份和
恢复 MySQL 数据库，连接时信任自签名 TLS 证书，并正确处理生成（虚拟/存储）列
和 BLOB 数据。

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

单元测试（无需数据库，用 stub 验证逻辑走线）：

```sh
brew install bats-core   # 一次性安装，macOS
bats tests/unit
```

集成测试（需要 Docker，启动真实 MySQL 验证端到端行为）：

```sh
bats tests/integration
```
