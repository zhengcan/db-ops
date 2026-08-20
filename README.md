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
```

注意：`--dir` 在 `backup` 和 `restore` 中的含义不同——`backup` 场景下它是
"存放新备份目录的基础路径"，`restore` 场景下它是"要读取的具体备份目录"。

## 配置文件

除了传参，也可以使用 KEY=VALUE 风格的配置文件：

```sh
# db.conf
DB_HOST=mysql.example.internal
DB_PORT=3306
DB_USER=backup_user
DB_PASSWORD=secret
```

```sh
./my-ops.sh info --config db.conf --database mydb
```

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

```sh
brew install bats-core   # 一次性安装，macOS
bats tests/unit
```

集成测试（需要 Docker，启动真实 MySQL 验证端到端行为）：

```sh
bats tests/integration
```
