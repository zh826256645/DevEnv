# 按安装路径映射数据库 TCP 监听状态

Environment Scan 从 `PATH`、Homebrew 和已识别 Local Service 的真实可执行文件路径发现 Database Installation，按软链接实际目标去重；只有 Local Service 的真实可执行文件路径精确匹配时，才标记为 Listening Database Installation。不按进程名或端口推断，也不连接或查询数据库，以避免多版本安装误匹配并保持只读的本地观察边界。

## Consequences

- 同一 Database Installation 的多个监听进程聚合为一个“正在监听”状态，不新建数据库实例模型。
- 仅使用 Unix Socket 或位于容器内的数据库不会被标记为正在监听；如需覆盖，由后续显式 Database Provider 扩展。
- Database Provider 失败时保留已发现结果并产生 Scan Notice；没有结果时 Database Discovery State 为“发现状态未知”，不表述为“未安装”。
- 只由 Local Service 发现且无法精确识别数据库类型的进程不创建 Database Installation；例如无法区分 MySQL 与 MariaDB 的 `mysqld` 时，保留 Local Service 并产生 Scan Notice，不猜测类型。
- Local Service 扫描失败或进程路径不可读时，Database Listening State 为“监听状态未知”，不降级为“未监听”。
