# macOS 系统环境扫描

状态：V1 与 Runtime 多版本发现已实现。

## 目标

Environment Scan 以只读方式观察当前 Mac 的基础系统信息和开发工具状态，生成一份可在应用重启后继续查看的 Machine Snapshot。首版回答“当前 App 环境实际能使用什么”，不负责诊断所有可能安装或修改用户环境。

## V1 范围

包含：

- macOS 版本与 Build
- 芯片架构
- 主机名
- 总内存
- 系统卷容量与可用空间
- 当前 App 继承的 `PATH`
- Node.js、Python、Go、Java、Rust、Ruby、Lua 的 Effective Runtime Installation
- Homebrew 可用性、版本与可执行文件路径

不包含：

- 服务、监听端口和容器状态
- 项目要求扫描与环境对比
- Shell 配置冲突诊断
- 环境修复或任何修改命令
- 历史快照、导出和跨设备同步
- 未激活 Runtime 版本的 Provider 发现

## 扫描契约

### Runtime

每类 Runtime 在 V1 中只解析当前 `PATH` 的第一个可执行文件，并记录版本和路径。固定清单如下：

| Runtime | 可执行文件 | 版本参数 |
|---|---|---|
| Node.js | `node` | `--version` |
| Python | `python3` | `--version` |
| Go | `go` | `version` |
| Java | `java` | `-version` |
| Rust | `rustc` | `--version` |
| Ruby | `ruby` | `--version` |
| Lua | `lua` | `-v` |

版本结果合并 stdout 和 stderr，取第一行非空文本并移除已知前缀；不强制解析为语义化版本号。

每项状态为：

- `已发现`：存在可执行文件并取得可识别版本文本。
- `未发现`：当前 `PATH` 没有对应可执行文件。
- `读取失败`：可执行文件存在，但命令超时或无法取得可识别结果。

### Homebrew

V1 只检查 Apple Silicon 和 Intel Mac 的标准安装位置：

- `/opt/homebrew/bin/brew`
- `/usr/local/bin/brew`

未找到标准路径时显示“未发现”，不加载 Shell 配置寻找自定义安装位置。

## 执行与安全边界

- 不加载或执行 `.zshrc`、`.zprofile` 等 Shell 配置。
- 不接受用户输入并拼接命令。
- 只执行产品内固定的只读命令和参数。
- 不请求管理员权限，不访问钥匙串或受保护目录。
- 每个外部命令最多等待 2 秒；超时只影响对应扫描项。
- 不启用 App Sandbox 的理由见 [ADR-0001](../adr/0001-run-without-app-sandbox.md)，但扫描能力仍保持只读。

## 快照与持久化

应用只保留最近一次可用 Machine Snapshot：

- 文件位置：`~/Library/Application Support/DevEnv/machine-snapshot.json`
- 编码：Swift `Codable` JSON
- V1 实现版本：`schemaVersion = 1`
- Runtime 多版本扩展版本：`schemaVersion = 2`
- 写入方式：原子替换
- 启动读取到损坏或不支持版本的文件时忽略该文件，不尝试迁移

Runtime 多版本扩展启用后，V1 快照视为不支持版本并立即重新扫描；Machine Snapshot 是可重建的本机缓存，不提供 V1 到 V2 的迁移。

只要 macOS 版本和芯片架构可读取，就允许保存部分快照。Runtime 或 Homebrew 单项缺失、失败都不会阻止持久化；无法建立主机基础信息时保留上一份快照，并展示本次扫描失败。

## 触发与界面

- 应用启动时自动扫描一次。
- 用户可以点击“重新扫描”；扫描期间按钮不可重复触发。
- 不执行定时或后台轮询。
- 界面固定使用中文，`macOS`、`Runtime`、`Homebrew`、`PATH` 等专有名词保留原文。
- 单页依次展示最近扫描时间、系统信息、Runtime、Homebrew、PATH 和扫描提示。
- PATH 默认折叠；整体失败显示横幅，局部失败显示在对应条目。

## Runtime 多版本扩展

扩展覆盖 Node.js、Python、Go、Java、Rust、Ruby、Lua，保持只读展示，不提供版本切换或修复。

### 发现与合并

1. 按当前 `PATH` 顺序遍历每类 Runtime 的所有同名可执行文件。
2. 以规范化路径和软链接实际目标去重；同一文件经 `PATH` 和 Runtime Provider 重复发现时只保留一项。
3. `PATH` 候选继续执行对应版本命令。命令失败时保留路径并标记“版本读取失败”。
4. Runtime Provider 补充未进入 `PATH` 的安装。Provider 已返回版本与路径时，只验证文件存在且可执行，不再次启动 Runtime。
5. Provider 报告安装但目标文件不存在或不可执行时，保留版本和预期路径，标记“可执行文件不可用”并加入扫描提示。

`PATH` 首个命中始终是 Effective Runtime Installation；即使该文件启动失败，Shell 也不会自动回退到后续路径。只有 `PATH` 中存在两个或以上已知且不同的版本时才标记 Runtime Conflict；版本相同的不同安装和 Provider-only 安装不构成冲突。

### Runtime Provider

首批 Runtime Provider：

| Runtime Provider | 覆盖 Runtime |
|---|---|
| Homebrew、mise | 全部现有 Runtime |
| nvm | Node.js |
| uv、pyenv | Python |
| macOS `java_home` | Java |
| rustup | Rust |
| rbenv | Ruby |

Go 和 Lua 首批不增加专用 Provider，由 `PATH`、Homebrew 和 mise 发现。asdf、fnm、Volta、gvm、RVM 不在首批范围。

Provider 优先调用官方只读命令；nvm 等没有独立可执行命令的工具读取其标准目录。Provider 可执行文件从当前 `PATH` 和固定标准位置解析；管理器根目录只采用 App 已继承的对应环境变量或默认标准位置，不读取 `.zshrc`、`.zprofile` 等 Shell 配置，也不递归扫描整个磁盘。

Provider 顺序执行并沿用每条外部命令 2 秒超时。单个 Provider 失败只在扫描提示中记录，不影响 `PATH`、其他 Provider 或 Machine Snapshot。完整取舍见 [ADR-0003](../adr/0003-source-aware-runtime-discovery.md)。

### 展示

- 每类 Runtime 的所有安装默认展开，不提供切换操作。
- 每项展示版本和可复制的绝对文件路径，不展示 Runtime Provider。
- 软链接以 `PATH` 中的调用路径为主；实际路径不同时同时展示。
- Effective Runtime Installation 始终排第一；其余 `PATH` 安装保持 PATH 优先级顺序；Provider-only 安装最后按版本倒序、路径作为同版本稳定次序。
- Runtime Conflict 只在对应 Runtime 标题旁显示“PATH 版本冲突”，不重复写入扫描提示。
- 扫描提示保留版本读取失败、可执行文件不可用和 Provider 失败。

## 验收场景

- 首次启动且没有持久化文件：自动扫描并显示当前结果，成功后写入最新快照。
- 已有快照再次启动：先可读取旧快照，自动扫描成功后替换为新快照。
- Lua 未安装：Lua 显示“未发现”，其他结果正常保存。
- 单个 Runtime 命令超时：该项显示“读取失败”，其他扫描继续。
- Homebrew 不在标准路径：显示“未发现”，不执行 Shell 配置。
- 主机基础信息无法建立：显示整体错误，磁盘中的上一份快照保持不变。
- 快照文件损坏或版本不支持：忽略旧文件并执行启动扫描。
- `PATH` 依次包含 Python 3.12 和 3.9：两项均展示，3.12 标记 Effective，Runtime 标题显示“PATH 版本冲突”。
- pyenv 安装 Python 3.11 和 3.12、当前只激活 3.12：两项均展示，3.11 不构成 Runtime Conflict。
- 同一 Runtime Installation 经软链接、`PATH` 和 Runtime Provider 重复发现：合并为一项，同时展示调用路径和不同的实际路径。
- `PATH` 首个 Runtime Installation 启动失败、第二个可用：首项仍标记 Effective 并显示“版本读取失败”。
- Provider 超时：保留其他来源的安装，扫描提示记录对应 Provider 失败。
- Provider 返回的可执行文件不可用：保留版本和预期绝对路径并显示错误。
- 读取 V1 快照：忽略旧快照并执行扫描，成功后写入 V2 快照。

## 相关决策

- [ADR-0001：不启用 App Sandbox](../adr/0001-run-without-app-sandbox.md)
- [ADR-0002：只读扫描并持久化最新环境快照](../adr/0002-read-only-environment-scan-snapshot.md)
- [ADR-0003：按 PATH 与 Provider 分层发现 Runtime](../adr/0003-source-aware-runtime-discovery.md)
