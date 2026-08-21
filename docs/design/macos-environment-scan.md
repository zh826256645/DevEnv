# macOS 系统环境扫描

状态：V1 已实现；Runtime 多版本发现待实现。

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
- 当前版本：`schemaVersion = 1`
- 写入方式：原子替换
- 启动读取到损坏或不支持版本的文件时忽略该文件，不尝试迁移

只要 macOS 版本和芯片架构可读取，就允许保存部分快照。Runtime 或 Homebrew 单项缺失、失败都不会阻止持久化；无法建立主机基础信息时保留上一份快照，并展示本次扫描失败。

## 触发与界面

- 应用启动时自动扫描一次。
- 用户可以点击“重新扫描”；扫描期间按钮不可重复触发。
- 不执行定时或后台轮询。
- 界面固定使用中文，`macOS`、`Runtime`、`Homebrew`、`PATH` 等专有名词保留原文。
- 单页依次展示最近扫描时间、系统信息、Runtime、Homebrew、PATH 和扫描提示。
- PATH 默认折叠；整体失败显示横幅，局部失败显示在对应条目。

## Runtime 多版本后续阶段

多版本发现不改变 V1 的 Effective Runtime Installation，而是在其外增加 `已发现安装` 集合：

1. 遍历当前 `PATH` 中所有同名可执行文件。
2. 解析规范化路径和软链接目标并去重。
3. 将 PATH 首个命中标记为 Effective Runtime Installation。
4. 同类 Runtime 出现多个不同安装时标记 Runtime Conflict。
5. 按需增加 mise、pyenv、nvm 等 Provider，发现未进入 PATH 的版本。

不通过递归扫描整个磁盘发现 Runtime。完整取舍见 [ADR-0003](../adr/0003-source-aware-runtime-discovery.md)。

## 验收场景

- 首次启动且没有持久化文件：自动扫描并显示当前结果，成功后写入最新快照。
- 已有快照再次启动：先可读取旧快照，自动扫描成功后替换为新快照。
- Lua 未安装：Lua 显示“未发现”，其他结果正常保存。
- 单个 Runtime 命令超时：该项显示“读取失败”，其他扫描继续。
- Homebrew 不在标准路径：显示“未发现”，不执行 Shell 配置。
- 主机基础信息无法建立：显示整体错误，磁盘中的上一份快照保持不变。
- 快照文件损坏或版本不支持：忽略旧文件并执行启动扫描。

## 相关决策

- [ADR-0001：不启用 App Sandbox](../adr/0001-run-without-app-sandbox.md)
- [ADR-0002：只读扫描并持久化最新环境快照](../adr/0002-read-only-environment-scan-snapshot.md)
- [ADR-0003：按 PATH 与 Provider 分层发现 Runtime](../adr/0003-source-aware-runtime-discovery.md)
