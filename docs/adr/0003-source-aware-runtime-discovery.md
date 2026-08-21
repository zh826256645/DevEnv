# 按 PATH 与 Provider 分层发现 Runtime

Runtime 多版本发现先遍历当前 `PATH` 中的同名可执行文件，以规范化路径和软链接目标去重，并将首个命中标记为 Effective Runtime Installation；mise、pyenv、nvm 等未激活版本后续通过对应 Provider 发现，不执行全磁盘盲扫，以避免高成本、误报和越界读取。

## Consequences

- PATH 阶段可以识别会影响当前命令解析的多实例和 Runtime Conflict。
- Provider 阶段负责补充未进入 PATH 的已安装版本，并保留安装来源。
- 新增 Runtime 时先支持 Effective Runtime Installation，再按实际需求增加 Provider。
