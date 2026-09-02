# DevEnv

> macOS 本地项目运行工作台。

DevEnv 是一个原生 macOS App，用来保存本地项目的运行方式，在统一界面中启动、停止和观察开发进程。

它把散落在终端历史、README 和个人记忆里的启动命令整理成明确的运行配置，并将会话输出、运行状态、监听端口、内存占用和仓库状态放到同一个工作台中。

DevEnv 不负责替代终端、包管理器或版本管理器。它调用项目本来就在使用的 Shell 和工具，并用 Machine Environment 扫描结果解释当前 Mac 是否具备项目声明的运行条件。

> 当前项目仍处于早期开发阶段，尚未提供可下载的 Tag 或 GitHub Release。

## 核心工作流

### 1. 添加项目

直接选择一个 Project Root，或选择临时的 Project Search Root 批量发现其中的项目。

DevEnv 只保存轻量的 Project Record。移除记录不会删除、移动或修改原项目目录；被移除的项目也不会在后续批量扫描中自动恢复，除非用户主动重新添加或恢复。

### 2. 配置运行方式

每个项目可以保存多个 Project Run Configuration，包括：

- 名称
- 启动命令
- Project Root 相对工作目录

运行配置可以手动创建，也可以从静态读取到的项目声明中采纳建议。目前支持从以下来源生成 Project Run Suggestion：

- `package.json` 中适合运行项目的 Node.js scripts
- `pyproject.toml` 中配合 uv 使用的项目 scripts
- `Cargo.toml` 中的 Rust bin target
- Compose 配置文件

建议只是候选配置。DevEnv 不会在扫描阶段自动执行项目工具或命令。

### 3. 首次确认信任

首次运行某个 Project Root 前，DevEnv 会展示完整命令和解析后的工作目录。用户确认后才会保存该 Project Root 的 Project Trust 并启动会话。

后续运行可以复用信任记录，但每次启动仍必须由用户明确触发。修改命令后，只有新命令成功启动才会写回已保存配置。

### 4. 运行项目

DevEnv 使用当前用户的 Default Login Shell 和 SwiftTerm PTY 创建 Project Run Session，支持：

- 启动、停止和重启单个运行配置
- 按当前筛选结果批量启动或停止
- 查看交互式终端输出
- 清空终端或放大查看会话
- 区分启动失败、异常退出、主动停止和停止失败

命令结束后会话保留退出码和只读终端输出，不会留下空闲的通用 Shell。

### 5. 观察运行状态

总览和运行页面集中展示：

- 活动会话及运行时长
- 当前 Git 分支或 detached HEAD 状态
- 会话所属进程的物理内存占用
- 可归属于会话的 TCP 监听端口
- 可能暴露到本机以外的监听地址
- 最近的运行失败、退出码和状态刷新异常

端口只在能够可靠归属于 Project Run Session 时显示；DevEnv 不根据目录名或命令文本猜测进程归属。

## 项目理解

DevEnv 会静态读取 Project Root 内的项目清单和版本文件，将各 Project Component 的声明归并成 Project Requirements，再与当前 Machine Environment 比较。

当前识别范围包括：

- Node.js、Python、Go、Java、Rust、Ruby 和 Lua 运行时要求
- uv、Bun、npm、pnpm 和 Yarn 包管理器要求
- 操作系统与处理器架构要求
- PostgreSQL、MySQL、MariaDB、MongoDB 和 Redis 数据库要求
- Compose 中能够静态确认的服务声明
- Python Component 内的项目本地 `.venv`

比较结果分为“已满足”“未满足”“无法判断”和“声明冲突”。它们只说明本机证据是否匹配项目声明，不保证项目一定能够运行。

项目分析不会执行项目代码、动态清单表达式或 Shell 配置，也不会自动安装、修复或启动项目依赖。

## Machine Environment 证据

Environment Scan 以当前 App 用户的可见范围观察本机状态，并保存最近一次成功的 Machine Snapshot。当前界面提供：

- macOS、处理器架构、内存和系统卷信息
- Homebrew Availability、PATH 和包管理器状态
- 常见语言运行时的版本、路径、来源和当前生效安装
- 数据库服务端安装及 TCP 监听状态
- 按 PID 聚合的 Local Service、监听地址和端口
- 当前生效的 Git CLI、Git LFS 和脱敏后的用户级 Git 配置
- 已安装的受支持 Terminal Application
- Shell Installation 与 Default Login Shell

Local Service 与 Homebrew Service 是两类不同事实：前者来自 TCP Listener Binding，后者来自 Homebrew 的服务声明。对于当前用户可管理的 Homebrew Service，DevEnv 支持在展示具体命令并确认后执行启动、停止和重启。

## 安全边界

DevEnv 需要观察本机工具并运行用户选择的项目命令，因此当前不启用 App Sandbox。使用源码版本前，应理解以下边界：

- Environment Scan 和 Project Requirements 分析是只读流程，不会因为扫描结果自动执行项目命令。
- Project Run 必须由用户明确触发；首次运行会展示完整命令和工作目录并要求确认。
- Project Trust 只表示允许 DevEnv 在对应 Project Root 中执行已核对的配置，不表示项目安全或环境满足要求。
- 项目命令以当前用户权限交给 Default Login Shell 执行，DevEnv 不隐藏或提升命令权限。
- 停止操作只会向能够由当前 PTY 会话可靠确认归属的进程组发送信号。
- Project Record、运行配置、信任记录和最近一次 Machine Snapshot 会保存在本机；会话状态、终端输出和退出码只存在于当前 App 进程。
- 退出 App 时会尝试终止仍由 DevEnv 持有的活动会话；关闭窗口不会结束它们。
- 移除 Project Record 不会删除或修改原项目文件。

Homebrew Service 等会改变本机状态的操作会先展示具体命令和影响，再等待用户确认。

## 从源码运行

### 要求

- macOS 15 或更高版本
- 支持 Swift 6 的 Xcode
- 首次构建时可访问 GitHub，以解析 SwiftTerm 依赖

### 步骤

```bash
git clone https://github.com/zh826256645/DevEnv.git
cd DevEnv
git switch develop
open DevEnv.xcodeproj
```

在 Xcode 中等待 Swift Package Manager 解析固定版本的 SwiftTerm，选择 `DevEnv` scheme 和 `My Mac`，然后运行项目。

DevEnv 当前使用本地开发签名，不提供正式安装包、自动更新或已发布版本的兼容性保证。

## 技术摘要

- Swift 6
- SwiftUI 与 AppKit
- Swift Concurrency 与 Combine
- SwiftTerm 1.11.2
- macOS `Process`、PTY 和 Darwin process API
- 本机 Application Support 持久化

项目采用单一领域上下文。术语、边界与关键设计决策见：

- [领域模型](CONTEXT.md)
- [为何不启用 App Sandbox](docs/adr/0001-run-without-app-sandbox.md)
- [只读 Environment Scan 与 Machine Snapshot](docs/adr/0002-read-only-environment-scan-snapshot.md)
- [Project Root 与 Project Component](docs/adr/0008-model-projects-by-root-and-component.md)
- [可信 Project Run 与 Environment Scan 的边界](docs/adr/0010-separate-trusted-project-runs-from-environment-scans.md)

## 参与项目

DevEnv 仍在早期开发阶段。Bug、功能需求和设计讨论请提交到 [GitHub Issues](https://github.com/zh826256645/DevEnv/issues)，代码变更可通过 [Pull Requests](https://github.com/zh826256645/DevEnv/pulls) 提交。

版本历史和后续计划以 Git 提交与 GitHub Issues 为准，不在 README 中维护重复路线图。

## License

本项目尚未设置开源许可证。
