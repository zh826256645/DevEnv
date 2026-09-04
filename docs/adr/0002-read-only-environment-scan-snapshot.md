# 只读扫描并持久化最新环境快照

> “不加载 Shell 配置”的限制已由 [ADR-0013](0013-initialize-machine-tool-search-path-from-login-shell.md) 在取得 Machine Tool Search PATH 的固定、限时调用范围内取代；快照的最小持久化边界仍然有效。

Environment Scan 调用固定的本机观察命令且不请求管理员权限，并将最近一次可建立主机基础信息的 Machine Snapshot 以 `Codable` JSON 原子写入 Application Support；除 ADR-0013 为取得 Machine Tool Search PATH 而进行的受限 Shell 初始化外，不加载 Shell 配置。这样应用重启后仍可查看结果，同时将任意用户脚本执行风险限制在明确记录的 PATH 观察边界内，并避免积累历史数据。

## Consequences

- Runtime 只展示 Machine Tool Search PATH 解析到的实例及 Provider 补充安装，未安装或读取失败会作为单项状态保留在快照中。
- 扫描失败不会覆盖上一份可用快照；首版不提供历史对比和迁移。
- 不启用 App Sandbox 是既有约束；除 ADR-0013 已记录的用户 Shell 初始化副作用风险外，DevEnv 的扫描命令不主动执行写操作。

完整首版契约见 [macOS 系统环境扫描](../design/macos-environment-scan.md)。
