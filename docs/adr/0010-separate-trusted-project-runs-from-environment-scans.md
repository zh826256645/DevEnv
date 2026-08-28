# 将可信 Project Run 与只读 Environment Scan 分离

Environment Scan 继续只执行固定的只读观察，不加载 Shell 配置，也不根据扫描结果自动启动项目命令。Project Run Suggestion 只提供候选运行意图；只有用户保存 Project Run Configuration，并在首次执行对应 Project Root 时核对完整命令与解析后的工作目录、建立 Project Trust，DevEnv 才创建 Project Run Session。

Project Run Session 使用当前用户可用的 Default Login Shell 和 SwiftTerm PTY，在每次启动前重新检查工作目录边界。只有 Project Trust 持久化在 App 私有存储中；终端输出、进程状态和退出码仅保留在当前 App 进程内。这样显式项目执行不会扩大只读 Environment Scan 的权限或持久化范围。

## Consequences

- Project Trust 只表示用户允许 DevEnv 在该 Project Root 中执行已核对的运行配置，不表示项目安全、健康或满足 Project Requirements。
- 工作目录或 Default Login Shell 在后续启动时失效会直接导致 launch failed，不按旧快照继续执行，也不回退到其他 Shell。
- 命令通过交互式登录 Shell 的单次 `-c` 调用执行；命令结束后 PTY 关闭并保留只读输出与退出码，不留下空闲通用 Shell。
- 停止和 App 退出作用于独立进程组，避免 Project Run Session 的子进程脱离会话遗留。
