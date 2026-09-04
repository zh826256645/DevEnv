# 从 Default Login Shell 初始化 Machine Tool Search PATH

Environment Scan 现在允许仅为取得 Machine Tool Search PATH 而启动当前账户记录中的 Default Login Shell，并让它完成适合该 Shell 的交互式登录初始化；这明确取代 ADR-0010 和 ADR-0002 中“Environment Scan 不加载 Shell 配置”的绝对限制。Shell 以按类型固定的参数和固定命令运行，普通 stdout/stderr 被丢弃，随机标记的帧协议通过独立临时文件只提取 `PATH`，并对结果进行非空、长度、控制字符和路径规范化校验；启动失败、超时、非零退出或输出无效时回退到 App 进程 `PATH` 并产生一条 Scan Notice。

## Consequences

- 加载 `.zprofile`、`.zshrc` 等初始化文件会执行用户编写或第三方安装的任意代码，可能产生文件、进程、网络访问或其他副作用；DevEnv 接受这一风险，以换取 LaunchServices 启动时与用户新建交互式登录 Shell 一致的工具解析结果。
- Shell 调用不接收项目或用户拼接的命令，也不提供用户输入；csh/tcsh 仅从标准输入接收固定命令流。调用使用 3 秒绝对截止时间，协议文件最多读取 128 KiB，超时后立即终止 Shell 而不等待其后台进程。
- Machine Snapshot 只保存规范化后的 Machine Tool Search PATH 及其来源，不保存 Shell 的其他输出、环境变量或凭据。
- Shell 从账户记录中的用户 Home Directory 启动，使该 PATH 保持全局用户 Shell 观察；它不代表既有终端窗口、Project Root、`direnv`、IDE 或容器中的目录局部环境。
