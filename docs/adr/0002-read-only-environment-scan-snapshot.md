# 只读扫描并持久化最新环境快照

Environment Scan 只调用固定的本机只读命令，不加载 Shell 配置、不请求管理员权限，并将最近一次可建立主机基础信息的 Machine Snapshot 以 `Codable` JSON 原子写入 Application Support；这样应用重启后仍可查看结果，同时避免扫描过程执行任意用户脚本或积累历史数据。

## Consequences

- 首版 Runtime 只展示当前 `PATH` 解析到的实例，未安装或读取失败会作为单项状态保留在快照中。
- 扫描失败不会覆盖上一份可用快照；首版不提供历史对比和迁移。
- 不启用 App Sandbox 是既有约束，扫描实现仍保持只读边界。

完整首版契约见 [macOS 系统环境扫描](../design/macos-environment-scan.md)。
