# 按 PATH 与 Provider 分层发现 Runtime

Runtime 多版本发现先遍历当前 `PATH` 中的同名可执行文件，以规范化路径和软链接目标去重，并将首个命中标记为 Effective Runtime Installation；只有 `PATH` 中同时存在版本不同的安装才构成 Runtime Conflict。未激活版本通过 Runtime Provider 的官方只读命令或标准目录发现，不加载 Shell 配置，也不执行全磁盘盲扫，以避免高成本、误报和越界读取。

## Consequences

- PATH 阶段识别会影响当前命令解析的多实例；Provider-only 安装不构成 Runtime Conflict。
- Runtime Provider 阶段补充未进入 `PATH` 的已安装版本，单个 Provider 失败不影响其他扫描结果。
- 新增 Runtime 时先支持 Effective Runtime Installation，再按实际需求增加 Provider。
