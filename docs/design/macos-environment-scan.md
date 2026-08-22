# macOS 系统环境扫描

状态：v0.1 范围已冻结，Runtime 多版本发现与总览界面已实现，并已通过 [PR #11](https://github.com/zh826256645/DevEnv/pull/11) 合并到 `master`。

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

### 窗口与信息层级

- V1 使用单一总览页，不提供侧边栏或尚未实现能力的空壳页面。
- 窗口可缩放，首次尺寸为 860×720pt，最小尺寸为 720×560pt；正文保持单列并在 900pt 最大宽度内居中。
- 最近扫描时间固定使用 `yyyy-MM-dd HH:mm:ss` 格式，并按本机时区显示。
- 标题下方首先展示一个圆角总览面板，面板内按双列划分系统信息与扫描汇总；每列由图标标题和独立内层卡片组成，两张内层卡片始终以内容较高的一侧为准保持可见背景等高，不使用固定高度。其后依次展示 Runtime 和环境配置，不在正文中重复系统信息或单独展示 Scan Notice 模块。
- 摘要只展示已发现 Runtime 类别数、Runtime Installation 总数和 Scan Notice 总数，不给出环境健康评分或“正常/异常”的整体判断。
- 系统信息卡使用大号系统 Apple 标志，集中展示 macOS 版本、Build、架构，并以图标指标展示主机名和内存；系统卷使用线性进度条显示已用容量占总容量的比例，并同时标注已用、可用和总容量。扫描汇总的三个指标分别使用带图标底板和细描边的独立圆角行，数值右对齐突出显示。
- Runtime 使用自适应卡片网格，随窗口宽度自动增减列数；扫描提示保持单列。Homebrew 与 PATH 合并到“环境配置”圆角模块内并使用双列等高卡片：Homebrew 展示版本、安装状态和可执行路径，PATH 展示目录总数与真实的 Runtime PATH 版本冲突数。PATH 详情默认折叠，点击“查看全部”后在双卡下方占满整行展开，避免把 Homebrew 卡片同步撑出空白。

### 扫描状态

- 应用启动时自动执行一次 Environment Scan，不执行定时或后台轮询。
- 没有可用 Machine Snapshot 时展示应用图标、“正在读取系统信息…”和不确定进度指示器，不伪造百分比或逐项进度。
- 已有 Machine Snapshot 时立即展示总览并标记“正在更新”；扫描完成后一次性替换整份快照，不混合新旧模块数据。
- 后台更新失败时保留旧快照，并明确展示当前结果的扫描时间、失败原因和“重新扫描”操作；没有旧快照时展示整页失败状态。
- 通知和“重新扫描”位于窗口右上角工具栏；重新扫描支持 `⌘R`，扫描期间禁用重复触发。

### 状态与交互

- Scan Notice 集中放入右上角通知弹窗；当前 Machine Snapshot 存在尚未查看的提示时，铃铛显示红点，打开弹窗即将当前快照标记为已读并隐藏红点，新 Machine Snapshot 再次产生提示时重新显示。冲突同时在对应 Runtime 行保留一次上下文标记，但通知列表不承担跳转或展开操作。
- 未安装 Runtime 或未发现 Homebrew 是中性状态，不构成 Scan Notice。
- Runtime 固定按 Node.js、Python、Go、Java、Rust、Ruby、Lua 排列，不按状态动态重排。
- Runtime 区域使用独立圆角容器和醒目的终端标题标识。每种 Runtime 使用一张至少 180pt 宽的独立卡片并自适应排列：左上角使用带浅色底板的本地矢量语言 Logo，右上角显示状态徽章，中部依次显示名称、Effective Runtime Installation 版本和安装数量，安装数量使用堆叠实例图标而非用户图标，底部以分隔线和状态胶囊展示“已安装”“未发现”“读取失败”或“PATH 版本冲突”。折叠卡片高度由内容和统一内边距自然决定，不设置额外最小高度。状态色同时用于卡片细描边、徽章和胶囊，Logo 只用于快速识别，不替代状态文字，并在浅色、深色模式保持清晰。同一时间只展开一张卡片；点击任意卡片时，它以无回弹的平滑布局动画移动到 Runtime 区域首位并占满整行，其他卡片统一重排到下方，避免标题文字随弹性动画在小数像素位置抖动。卡片不显示展开箭头，展开时提高背景和描边对比度；辅助功能仍明确读出“已展开”或“已折叠”。卡片重排只使用布局动画，详情作为一个整体淡入，不对整张卡片使用跨容器几何匹配，也不为每条安装路径叠加位移动画，避免切换期间同时合成新旧视图形成拖影。应用重启后恢复折叠；启用“减少动态效果”时不执行动画。
- Runtime Installation 路径、实际路径和 PATH 条目使用等宽字体并允许文本选择；复制按钮默认隐藏，在鼠标悬停或键盘聚焦路径行时显示，复制后短暂显示“已复制”。
- Runtime 大卡默认最多展示前 3 个 Runtime Installation；存在更多安装时显示剩余数量，用户可展开全部或收起至前 3 个。
- `PATH 版本冲突`、Runtime 读取失败和单条 Runtime Installation 失败提示旁显示问号图标；鼠标悬停时在问号附近显示轻量说明弹层，解释状态含义和影响，不增加点击层级。说明弹层使用 SwiftUI 原生悬停状态和 Popover，不在整卡按钮内嵌会随按钮悬停重建的 AppKit Tracking View。
- 状态同时使用 SF Symbol、文字和颜色表达：绿色表示已发现，灰色表示未发现，橙色表示需注意，红色只用于无法建立 Machine Snapshot 的整体失败。
- 界面使用原生 SwiftUI 组件并自动适配浅色与深色；只使用系统加载和展开动画，并遵循“减少动态效果”设置。
- 界面使用中文语义，`macOS`、`Runtime`、`Runtime Installation`、`Homebrew`、`PATH` 等约定专名保留原文；Effective Runtime Installation 在界面中标记为“当前生效”。

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

- 每类 Runtime 默认折叠，通过行内展开查看所有安装，不提供版本切换操作。
- 每项展示版本和可复制的绝对文件路径，不展示 Runtime Provider。
- 软链接以 `PATH` 中的调用路径为主；实际路径不同时同时展示。
- Effective Runtime Installation 始终排第一；其余 `PATH` 安装保持 PATH 优先级顺序；Provider-only 安装最后按版本倒序、路径作为同版本稳定次序。
- Runtime Conflict 在扫描提示中集中展示，并在对应 Runtime 行旁显示“PATH 版本冲突”。
- 扫描提示保留版本读取失败、可执行文件不可用和 Provider 失败。

## 验收场景

- 首次启动且没有持久化文件：自动扫描并显示当前结果，成功后写入最新快照。
- 已有快照再次启动：先可读取旧快照，自动扫描成功后替换为新快照。
- 已有快照但自动扫描失败：继续展示旧快照，并明确标记其扫描时间和更新失败原因。
- Lua 未安装：Lua 显示“未发现”，其他结果正常保存。
- 单个 Runtime 命令超时：该项显示“读取失败”，其他扫描继续。
- Homebrew 不在标准路径：显示“未发现”，不执行 Shell 配置。
- 主机基础信息无法建立：显示整体错误，磁盘中的上一份快照保持不变。
- 快照文件损坏或版本不支持：忽略旧文件并执行启动扫描。
- `PATH` 依次包含 Python 3.12 和 3.9：两项均展示，3.12 标记“当前生效”，Runtime 行和扫描提示显示“PATH 版本冲突”。
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
