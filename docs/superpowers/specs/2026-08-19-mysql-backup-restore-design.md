# MySQL 备份恢复工具设计文档

## 目标

在裸 Alpine 环境下运行的单个 shell 脚本，支持对 k8s 中部署的 MySQL 数据库
（含所有用户表、视图、存储过程/函数、触发器、事件）进行完整 DDL+DML 备份
与恢复，兼容自签名 TLS 证书，正确处理虚拟/生成列。

## 依赖（启动时自动 apk 安装）

脚本启动时检测以下命令/包是否存在，缺失则执行 `apk add --no-cache <pkg>`：

- `mariadb-client`（提供 `mysql` / `mysqldump` / `mysqladmin`）
- `mariadb-connector-c`（底层连接库，部分 Alpine 版本不会自动拉全）
- `gzip`（压缩，一般 busybox 自带，缺失则补装）
- `gawk`（用于生成列的 INSERT 列名替换，行为比 busybox awk 更可靠）

## 脚本结构

单文件 `my-ops.sh`，POSIX `sh` 编写，子命令：

```
./my-ops.sh info    [连接与配置参数]
./my-ops.sh backup   [连接与配置参数] [--database db1,db2 | --all-databases]
./my-ops.sh restore  [连接与配置参数] --dir <backup_dir> --database db1,db2 [--force]
```

## 配置

- `--config <file>`：KEY=VALUE 风格配置文件（如 `DB_HOST=`、`DB_PORT=`、
  `DB_USER=`、`DB_PASSWORD=`、`DB_NAME=`），脚本 `source` 载入
- 命令行参数可覆盖同名配置项，优先级：命令行 > 配置文件
  - `--host` `--port` `--user` `--password` `--database` `--all-databases`
    `--force` `--dir` `--config`
- 密码建议通过 `DB_PASSWORD` 环境变量或配置文件传入，避免明文出现在命令行
  历史/进程列表中

## 连接安全（自签名 TLS）

所有 `mysql` / `mysqldump` / `mysqladmin` 调用固定加入：

```
--ssl --skip-ssl-verify-server-cert
```

即强制加密传输，但不校验服务器证书链/主机名合法性，满足自签名证书场景。

密码通过临时生成的 `--defaults-extra-file`（内容为 `[client]\npassword=...`）
传递，避免明文出现在 `ps` 输出中；使用后立即 `rm -f` 删除该临时文件（含在
`trap` 清理逻辑中，保证异常退出也能清理）。

## `info` 子命令

- `mysqladmin ping` 测试连接是否正常，失败则报错退出
- 列出目标库列表（若指定 `--all-databases` 则查询
  `information_schema.SCHEMATA` 排除
  `mysql/information_schema/performance_schema/sys`）
- 对每个库输出对象概览：表数量、视图数量、存储过程/函数数量、触发器数量、
  事件数量（通过查询 `information_schema.TABLES` / `ROUTINES` /
  `TRIGGERS` / `EVENTS`）

## `backup` 子命令

### 库范围

- `--database db1,db2`：逗号分隔的显式库名列表
- `--all-databases`：自动发现所有非系统库
- 两者互斥，必须二选一

### 输出结构

- 每次执行创建一个带时间戳的目录：`backup_<YYYYMMDD_HHMMSS>/`
- 每个库输出一个独立文件：`<backup_dir>/<db>.sql.gz`

### 单库导出流程

1. **Schema 部分**：
   ```
   mysqldump --no-data --routines --triggers --events \
     --ssl --skip-ssl-verify-server-cert \
     --defaults-extra-file=<tmp_cnf> -h $HOST -P $PORT -u $USER $DB
   ```
   覆盖所有用户表、视图、存储过程/函数、触发器、事件的 DDL；生成列定义
   完整保留在 `CREATE TABLE` 语句中。

2. **Data 部分**：
   ```
   mysqldump --no-create-info --complete-insert --skip-extended-insert \
     --hex-blob --single-transaction \
     --ssl --skip-ssl-verify-server-cert \
     --defaults-extra-file=<tmp_cnf> -h $HOST -P $PORT -u $USER $DB
   ```
   - `--single-transaction`：InnoDB 一致性快照，不加表锁
   - `--complete-insert`：每条 INSERT 显式列出列名（恢复阶段生成列处理
     依赖此格式）
   - `--skip-extended-insert`：每行一条 INSERT，便于恢复阶段按行做列名
     替换
   - `--hex-blob`：BLOB/二进制字段以十六进制字符串导出，避免转义/编码
     问题，确保二进制数据（图片、加密内容等）备份恢复不丢失

3. 将 schema 部分 + data 部分拼接为一个 `.sql` 文件，`gzip` 压缩后写入
   `<backup_dir>/<db>.sql.gz`

## `restore` 子命令

```
./my-ops.sh restore --dir <backup_dir> --database db1,db2 [--force]
```

- **必须显式指定库名列表**（逗号分隔），不支持自动恢复目录内全部库文件，
  避免误操作；脚本据此定位 `<backup_dir>/<db>.sql.gz` 文件，缺失则报错
- 无 `--force` 参数时，对每个待恢复库执行二次交互确认（因涉及
  `DROP DATABASE`），用户需输入确认后才继续；`--force` 跳过确认，
  适用于自动化场景

### 单库恢复流程

1. 解压 `<db>.sql.gz`（识别 `.gz` 后缀自动 `gzip -dc`）
2. `DROP DATABASE IF EXISTS <db>;` + `CREATE DATABASE <db>;`
3. 导入 schema 部分 → 建表（生成列定义原样保留，不做任何改动）
4. 查询目标库（刚建好的库）`information_schema.COLUMNS`，找出每张表中
   `GENERATION_EXPRESSION` 不为空的列（生成列），记录列名及对应
   `COLUMN_TYPE`
5. 对每个生成列 `A`：
   ```
   ALTER TABLE tbl ADD COLUMN A__tmp <COLUMN_TYPE> NULL;
   ```
   纯新增操作，不触碰原生成列 `A` 本身，索引/唯一约束/外键均不受影响。
   临时列使用双下划线 `__tmp` 后缀（而非单下划线 `_tmp`）以进一步降低
   与用户已有列名冲突的概率。生成列的映射以 `(表名, 列名)` 为键（而非
   仅列名）区分，因此不同表各自拥有名称相同的生成列（例如
   `products.total` 和 `inventory.total` 都是生成列）时，两者的
   `__tmp` 暂存与清理互不影响、不会相互覆盖或碰撞；已通过单元测试
   （`tests/unit/gencol_filter.bats`、`tests/unit/restore.bats` 中
   "same-named generated column" 相关用例）验证。
6. 用 `gawk` 对 data 部分做文本替换：仅在 `INSERT INTO `tbl` (...)` 的
   列名列表部分，将生成列名 `A` 替换为 `A__tmp`；不触碰 `VALUES` 部分
   （避免解析转义字符串、十六进制 blob 字面量的复杂度和风险）
7. 导入替换后的 data 部分 → 数据成功写入 `A__tmp`；生成列 `A` 由数据库
   根据同一行内其他真实列的数据自动计算，与 `A__tmp` 无关
8. 清理：对每个临时列执行
   ```
   ALTER TABLE tbl DROP COLUMN A__tmp;
   ALTER TABLE tbl DROP COLUMN B__tmp;
   ```
   删除所有临时列。**实际实现采用每列单独一条 ALTER 语句而非批量合并**：
   实现更简单直观（新增/清理逻辑对称，都是"遍历 map 文件，逐列发一条
   语句"），代价是同一张表有多个生成列时会多发起几次 mysql 连接/语句；
   对典型场景（每张表生成列数量通常很少）而言这点连接开销可以忽略，
   因此选择用简单性换取这点性能。

## 错误处理

- 脚本头部 `set -eu`，出现未处理错误立即退出
- 前置校验：
  - 依赖检测与自动安装（apk 命令是否可用、是否为 root）
  - 连接测试（`mysqladmin ping`）
  - `restore` 时校验 `--dir` 目录及对应 `<db>.sql.gz` 文件是否存在
- 出错时输出清晰的错误信息并以非零状态码退出
- 临时文件（`--defaults-extra-file`、解压中间文件等）通过 `trap ... EXIT`
  保证清理

## 已知局限

- 生成列上如存在索引/唯一约束/外键，本设计不需要处理索引重建问题——
  因为方案本身不改动生成列 `A`，只新增独立的 `A__tmp` 临时列，索引天然
  不受影响
- 脚本假定运行环境可直接网络访问 MySQL 服务（端口转发 / NodePort /
  ClusterIP 均可，只要网络可达），不依赖 `kubectl exec` 或作为 k8s
  Job/CronJob 运行
- `--config <file>` 是通过 shell `.` (source) 直接执行的，等价于在当前
  shell 中执行任意代码，而不是一个受限的 KEY=VALUE 解析器。这一设计假定
  配置文件来源可信（本地文件系统、由运维人员自己维护）；如果配置文件路径
  可能来自不可信输入（例如由外部系统拼接生成、或来自用户可控的上传内容），
  这里就是一个任意代码执行点。本次修复不改变这一实现方式（保持 shell 原生、
  零依赖），仅将其记录为已知的信任边界。
- `mysqldump --routines --triggers --events` 默认会在存储过程/触发器/事件
  的 DDL 中带上 `DEFINER=` 子句。恢复到目标服务器时，如果该 DEFINER 对应
  的用户在目标服务器上不存在，创建这些对象通常仍会成功（MySQL/MariaDB
  允许 DEFINER 指向不存在的用户），但后续以该 DEFINER 身份执行这些对象时
  会因权限或用户不存在而失败。因此推荐使用具有足够权限（通常是
  root/SUPER，或明确拥有 `SET USER` / `CREATE ROUTINE` 等相关权限）的账号
  执行 restore，且在跨环境迁移时留意 DEFINER 用户是否需要在目标库上同步
  创建。
- 中途中断（Ctrl-C/SIGTERM/进程意外崩溃）会在远程数据库上留下结构性的
  半成品状态，`trap ... EXIT` 只能清理本地临时文件，无法回滚已经发给
  MySQL 服务器的 DDL/DML：
  - 如果中断发生在 `DROP DATABASE` 和 `CREATE DATABASE` 之间，目标库会
    处于"已删除但未重建"的状态，需要人工重新执行 restore。
  - 如果中断发生在 `ADD COLUMN <col>__tmp` 和对应的
    `DROP COLUMN <col>__tmp` 之间，目标表上会永久遗留一个 `__tmp` 临时列。
    可以用以下查询检测某个库上是否有遗留的临时列：
    ```sql
    SELECT TABLE_NAME, COLUMN_NAME
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA='<db>' AND COLUMN_NAME LIKE '%__tmp';
    ```
    确认是遗留物（而非业务上刻意使用了这个命名）后，手动执行
    `ALTER TABLE <table> DROP COLUMN <column>__tmp;` 清理即可。
- `GENCOL_AWK_PROGRAM` 依赖 `mysqldump --complete-insert` 输出格式的一个
  隐式假设：INSERT 语句列名列表中的分隔符严格是 `", "`（逗号+一个空格）。
  这是当前使用的 mariadb-client 版本的实际输出格式；如果未来版本的
  mysqldump/mariadb-dump 改变了这一格式，或者列名本身包含字面逗号
  （MySQL 标识符语法上允许但实践中极为罕见），列名列表的解析会错位。这是
  已知局限，不在本次修复范围内。

## 验证计划

由于当前没有真实 k8s MySQL 环境可用于自动化测试，实现完成后按以下步骤
人工验证：

1. 使用容器（如 docker/podman）启动一个带自签名 TLS 证书的 MySQL 实例，
   建表时包含至少一个虚拟生成列（VIRTUAL）和一个存储生成列（STORED），
   并包含 BLOB 二进制字段、视图、存储过程、触发器、事件
2. 执行 `./my-ops.sh info` 验证连接成功（自签名证书不报错）且对象概览
   数量正确
3. 执行 `./my-ops.sh backup --database <db>`，验证目录结构
   `backup_<timestamp>/<db>.sql.gz` 生成正确
4. 执行 `./my-ops.sh restore --dir <backup_dir> --database <db>`，验证：
   - 表结构、索引、约束与源库一致
   - 生成列（虚拟/存储）恢复后计算结果与源库一致
   - 视图、存储过程/函数、触发器、事件正确恢复
   - BLOB 二进制字段内容恢复后与源数据逐字节一致（如用 `MD5()` 或
     `CHECKSUM TABLE` 比对）
   - 恢复后表中不residual 遗留任何 `__tmp` 临时列
5. 重复执行 backup → restore 验证幂等性（多次恢复到同一状态不报错）
