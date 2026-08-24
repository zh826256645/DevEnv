# 按工作目录与 App 路径识别运行时服务归属

Environment Scan 只为 Python 与 Node Local Service 识别 Local Service Attribution：Python 优先使用最近项目根及 PEP 621 名称；Node 使用包含工作目录的 Git 根目录名作为标题，同时使用最近的 `package.json` 包根作为运行目录，没有 Git 项目时才完全使用最近的包项目。缺少项目证据时再从可执行文件所在 `.app` 确认宿主 App。该顺序让单仓多包中的 Node 服务显示实际项目名，而不是 `frontend` 等子目录包名，同时保留 `frontend` 这类真实运行目录，并避免把端口、API 或运行时名称误当成业务归属。

## Consequences

- 不读取或持久化完整命令行，不遍历父进程，也不按参数、端口或 API 猜测归属。
- Node 项目标题与运行目录可来自不同层级；例如标题为 `personal-os`，运行目录为 `~/Projects/personal-os/frontend`。
- 项目、App 和通用运行时按该优先级展示；归属不同的 Local Service 不合并。
- 工作目录、项目声明或可执行路径不可读时静默回退，不产生 Scan Notice。
