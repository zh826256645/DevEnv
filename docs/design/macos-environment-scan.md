# macOS 系统环境扫描

状态：v0.1 范围已冻结；Runtime 多版本发现、TCP 监听服务、Git Tooling State、Terminal Application、Shell Installation 与总览界面已实现。

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
- TCP 监听服务扩展版本：`schemaVersion = 3`
- Git CLI 扩展版本：`schemaVersion = 4`
- User Git Configuration 扩展版本：`schemaVersion = 5`
- Git LFS、签名与 Credential Helper Chain 扩展版本：`schemaVersion = 6`
- GitHub Authentication Configuration 扩展版本：`schemaVersion = 7`
- Runtime Installation 来源扩展版本：`schemaVersion = 8`
- PostgreSQL Database Installation 纵向基线：`schemaVersion = 9`
- MySQL 与 MariaDB Database Installation 扩展：`schemaVersion = 10`
- MongoDB 与 Redis Database Installation 完整扩展：`schemaVersion = 11`
- Python 与 Node Local Service Attribution 扩展：`schemaVersion = 12`
- Terminal Application 与 Shell Installation 扩展：`schemaVersion = 13`
- 写入方式：原子替换
- 启动读取到损坏或不支持版本的文件时忽略该文件，不尝试迁移

Terminal Application 与 Shell Installation 扩展启用后，V1–V12 快照视为不支持版本并立即重新扫描；Machine Snapshot 是可重建的本机缓存，不提供旧版本迁移。

只要 macOS 版本和芯片架构可读取，就允许保存部分快照。Runtime、Homebrew、Terminal Application、Shell Installation、Git CLI、Git LFS 或 User Git Configuration 子项缺失、失败都不会阻止持久化；无法建立主机基础信息时保留上一份快照，并展示本次扫描失败。

## 触发与界面

### 窗口与信息层级

- 使用原生侧边栏提供“总览”“Runtime”“数据库”和“本地服务”四个已实现页面，默认进入总览，不提供尚未实现能力的空壳页面。
- 窗口可缩放，首次尺寸为 860×720pt，最小尺寸为 720×560pt；侧边栏宽度为 200–260pt，详情正文在 1100pt 最大宽度内居中。
- 最近扫描时间固定使用 `yyyy-MM-dd HH:mm:ss` 格式，并按本机时区显示。
- 总览页依次展示 Runtime 类别、已发现数据库类别、Local Service 组数和环境配置项数四张指标卡，以及双列的系统信息与环境状态，最后展示环境配置；不在正文中单独展示 Scan Notice 模块。
- 环境状态展示 PATH 冲突、未发现 Runtime、已发现但未监听的数据库和非回环 TCP Listener Binding 数量；任一数量大于零时整体标记“需关注”，否则标记“正常”。该摘要不改变 Scan Notice 的定义，也不证明对应工具或服务健康可用。
- 系统信息卡使用大号系统 Apple 标志，集中展示 macOS 版本、Build、架构，并以图标指标展示主机名和内存；系统卷使用线性进度条显示已用容量占总容量的比例，并同时标注已用、可用和总容量。
- Runtime、数据库和本地服务页各自先展示四张指标卡，再展示完整列表；Runtime 与数据库列表固定使用双列卡片网格，本地服务使用单列列表。Homebrew、Git、PATH、Terminal 与 Shell 只在总览页的“环境配置”中作为同级卡片展示。Terminal 摘要展示已发现应用数量，展开后按支持清单顺序展示名称、版本和应用路径；Shell 摘要展示 Default Login Shell 与已发现数量，展开后将默认项置顶并展示名称、路径、默认标记和可用状态。五张卡片复用同一时间只展开一张、选中卡片置顶并占满整行的交互。

### 扫描状态

- 应用启动时自动执行一次 Environment Scan；Environment Scan 本身不定时轮询，周期更新仅执行后文定义的 Dynamic Status Refresh。
- 没有可用 Machine Snapshot 时展示应用图标、“正在读取系统信息…”和不确定进度指示器，不伪造百分比或逐项进度。
- 已有 Machine Snapshot 时立即展示总览并标记“正在更新”；扫描完成后一次性替换整份快照，不混合新旧模块数据。
- 后台更新失败时保留旧快照，并明确展示当前结果的扫描时间、失败原因和“重新扫描”操作；没有旧快照时展示整页失败状态。
- 通知和“重新扫描”位于窗口右上角工具栏；重新扫描支持 `⌘R`，扫描期间禁用重复触发。

### 状态与交互

- Scan Notice 集中放入右上角通知弹窗；当前 Machine Snapshot 存在尚未查看的提示时，铃铛显示红点，打开弹窗即将当前快照标记为已读并隐藏红点，新 Machine Snapshot 再次产生提示时重新显示。冲突同时在对应 Runtime 行保留一次上下文标记，但通知列表不承担跳转或展开操作。
- 未安装 Runtime 或未发现 Homebrew 是中性状态，不构成 Scan Notice。
- Runtime 固定按 Node.js、Python、Go、Java、Rust、Ruby、Lua 排列，不按状态动态重排。
- Runtime 页面固定使用双列卡片网格。每种 Runtime 使用一张独立卡片：左侧使用带浅色底板的本地矢量语言 Logo，右侧显示名称、Effective Runtime Installation 版本、安装数量和“已安装”“未发现”“读取失败”或“PATH 版本冲突”状态。状态色同时用于卡片细描边和状态标识，Logo 只用于快速识别，不替代状态文字，并在浅色、深色模式保持清晰。同一时间只展开一张卡片；点击任意卡片时，它以无回弹的平滑布局动画移动到列表首位并占满整行，其他卡片统一重排到下方。卡片不显示展开箭头，展开时提高背景和描边对比度；辅助功能仍明确读出“已展开”或“已折叠”。卡片重排只使用布局动画，详情作为一个整体淡入，不对整张卡片使用跨容器几何匹配，也不为每条安装路径叠加位移动画，避免切换期间同时合成新旧视图形成拖影。应用重启后恢复折叠；启用“减少动态效果”时不执行动画。
- Runtime Installation 路径、实际路径和 PATH 条目使用等宽字体并允许文本选择；复制按钮默认隐藏，在鼠标悬停或键盘聚焦路径行时显示，复制后短暂显示“已复制”。
- Runtime 大卡默认最多展示前 3 个 Runtime Installation；存在更多安装时显示剩余数量，用户可展开全部或收起至前 3 个。
- 卡片网格中的详情统一复用 Runtime 交互：点击摘要区展开或收起，选中卡片置顶并占满整行，其余卡片自适应重排；没有详情的卡片不可展开。Environment Scan 更新后保留仍有效的展开态，详情消失时自动收起。
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
- 每项展示版本、Runtime Installation Source 和可复制的绝对文件路径。来源与“当前生效”“PATH”“未进入 PATH”状态分开展示；已知 Provider 来源优先，无法归属时显示“系统”或“PATH”。
- 软链接以 `PATH` 中的调用路径为主；实际路径不同时同时展示。
- Effective Runtime Installation 始终排第一；其余 `PATH` 安装保持 PATH 优先级顺序；Provider-only 安装最后按版本倒序、路径作为同版本稳定次序。
- Runtime Conflict 在扫描提示中集中展示，并在对应 Runtime 行旁显示“PATH 版本冲突”。
- 扫描提示保留版本读取失败、可执行文件不可用和 Provider 失败。

## Terminal Application 与 Shell Installation 扩展

### Terminal Application

- 固定支持 Terminal.app、iTerm2、Warp、Ghostty、Alacritty、kitty 与 WezTerm，并按该顺序通过 Bundle ID 使用 Launch Services 查询；不遍历应用目录或按名称猜测。
- 每项只保存名称、版本、Bundle ID 和应用路径；不推断 Default Terminal Application 或启动 DevEnv 的 Terminal Session。
- 未发现受支持应用与版本缺失均为中性状态，不产生 Scan Notice。

### Shell Installation

- 只读取 `/etc/shells` 的非空、非注释绝对路径，并补充 POSIX 当前账户记录中的 Default Login Shell；不遍历 `PATH`、常见安装目录或 Shell 配置文件。
- 规范化路径并去重，Default Login Shell 置顶，其余保持 `/etc/shells` 原始顺序。每项保存名称、路径、默认标记和可用状态，不启动 Shell 读取版本。
- 无法读取 `/etc/shells` 或当前账户 Default Login Shell 时产生独立 Scan Notice；默认路径未注册、已不存在或不可执行时仍保留为不可用项并产生 Scan Notice。Shell 数量不构成健康判断。

## Git Tooling State 扩展

- 按当前 `PATH` 顺序只取第一个可执行 `git`，记录规范化的绝对调用路径，不枚举其他安装来源或软链接目标。
- 只以已发现的绝对路径和固定参数 `--version` 直接启动进程，不调用 Shell，不拼接用户输入，并沿用单命令 2 秒超时。
- 状态固定为“可用”“未发现”或“读取失败”。未发现保持中性且不产生 Scan Notice；命令失败、超时或版本输出不可识别时保留路径并只产生一条 Git CLI Scan Notice。
- Git CLI 子扫描失败不丢弃系统、Homebrew Availability、PATH、Runtime Installation 或 Local Service 结果，也不改变主机基础信息可用时 Machine Snapshot 的可持久化性。
- Git CLI 随整份 Machine Snapshot 原子持久化和恢复，应用启动扫描与手动“重新扫描”继续共用现有刷新模型。
- Git CLI 可用后，固定以 `git config --global --get` 分别查询 `user.name`、`user.email`、`init.defaultBranch`，并以 `git config --global --path --get core.excludesFile` 查询用户显式 ignore 路径；不列举全量配置，不读取 system、repository-local 或 conditional include 的实际仓库身份。
- User Excludes File 优先采用显式配置；未配置时采用 `$XDG_CONFIG_HOME/git/ignore`，`XDG_CONFIG_HOME` 为空则采用 `$HOME/.config/git/ignore`。Machine Snapshot 只保存标准化绝对路径、来源和文件是否存在，不读取规则内容。
- 默认身份、默认分支或 User Excludes File 缺失均为中性状态，不产生 Scan Notice。配置命令失败或超时只产生一条 User Git Configuration Scan Notice，并保留 Git CLI、其他扫描结果和快照可持久化性；Git 未发现或版本读取失败时跳过配置子扫描。
- “环境配置”中的 Git 卡片默认折叠；展开态顶部与 Runtime、Homebrew 使用一致的横向摘要，左侧显示 Git 版本与状态，右侧显示 Git LFS、默认分支与 GitHub CLI 认证概览；其下显示可复制的 Git CLI 路径、自适应双列配置卡片和全宽 GitHub Authentication Configuration 表格。配置卡片包含基础信息、Default Git Identity、签名配置和 Credential Helper Chain，并复用键盘、VoiceOver 与“减少动态效果”交互，不计算就绪度、健康分或配置完成度。
- Git CLI 可用时，按当前 `PATH` 顺序只取第一个可执行 `git-lfs` 并以固定参数 `version` 读取版本；不扫描任何仓库的 LFS 跟踪规则、对象、缓存或同步状态。未发现保持中性，版本读取失败或超时只产生一条 Git LFS Scan Notice。
- 签名子扫描只以 `git config --global --get` 查询 `gpg.format`、`user.signingKey`、`commit.gpgSign` 和 `tag.gpgSign`；不枚举、打开或验证 SSH/GPG 密钥，不访问钥匙串或 agent。缺失值显示“未配置”，命令失败只隔离签名详情并产生一条对应 Scan Notice。
- Credential Helper Chain 只以 `git config --global --null --get-all credential.helper` 读取全部用户级值并保留顺序。Machine Snapshot 在编码前移除标准 helper 参数和路径，只保留 helper 标识；`!` 自定义命令只保存“自定义命令”，空值保存为 chain 重置事实。`store` 与其他 helper 一样只作事实展示，不评分或建议修复。
- Git 未发现或版本读取失败时跳过 Git LFS、签名和 Credential Helper Chain 子扫描；任一配置子扫描失败仍保留 Git CLI、User Git Configuration 的其他子项、Machine Environment 数据及快照可持久化性。
- GitHub Authentication Configuration 独立于 Git CLI 扫描。认证文件依次采用非空 `$GH_CONFIG_DIR/hosts.yml`、`$XDG_CONFIG_HOME/gh/hosts.yml`、`$HOME/.config/gh/hosts.yml`，只通过 Machine Access 检查文件存在性；进程级来源只记录非空 `GH_TOKEN` 与 `GITHUB_TOKEN` 是否存在。
- 按当前 `PATH` 顺序只取第一个可执行 `gh`，固定执行 `gh config get git_protocol --host github.com`；未发现 CLI 或配置保持中性，命令失败或超时只产生一条 GitHub CLI Configuration Scan Notice。Environment Scan 不执行 `gh auth status`、GitHub API 请求或任何联网认证测试，遵循 [ADR-0004](../adr/0004-keep-environment-scan-local.md)。
- Machine Snapshot 只保存 GitHub CLI 状态、`git_protocol` 和三种认证来源的布尔状态，不保存认证文件路径或内容、账号名及 token。Git 卡片只使用“已配置”“未配置”，不声称来源已登录、已认证或凭据有效。

## Database Installation 扩展

状态：PostgreSQL、MySQL、MariaDB、MongoDB 与 Redis 已完整实现。只读展示 Database Installation 及其 TCP 监听状态，不连接或查询数据库。

### 发现与匹配

1. 按当前 `PATH` 遍历已知数据库服务端可执行文件，Homebrew Database Provider 补充未进入 `PATH` 的安装。
2. Local Service Database Provider 使用 PID 读取进程真实可执行文件路径，并补充未被 `PATH` 或 Homebrew 发现的正在监听安装。
3. 以规范化路径和软链接实际目标去重；只有 Local Service 的真实可执行文件路径与 Database Installation 实际路径精确匹配时，才标记为“正在监听”，不按进程名或端口猜测。
4. 每项展示版本、调用路径和不同的实际路径。版本读取失败时保留 Database Installation，并产生 Scan Notice。
5. 只由 Local Service 发现且无法精确识别数据库类型的进程不创建 Database Installation；例如无法区分 MySQL 与 MariaDB 的 `mysqld` 时，保留 Local Service 并产生 Scan Notice。

Database Discovery State 为“已发现”“未发现”或“发现状态未知”。任一适用 Database Provider 失败时保留已有结果并产生 Scan Notice；没有结果时显示“发现状态未知”，不声称“未安装”。

Database Listening State 为“正在监听”“未监听”或“监听状态未知”。适用 Database Provider 失败且没有精确监听匹配、Local Service 扫描失败或已识别数据库进程的真实路径不可读时不猜测完整状态；已发现 Database Installation 自身可精确确定的监听状态不受影响。同一 Database Installation 的多个监听进程聚合为一个“正在监听”状态，不建立数据库实例模型。

该扩展只观察 TCP Listener Binding，不覆盖仅使用 Unix Socket 或容器内的数据库。如需覆盖，由后续显式 Database Provider 扩展。完整取舍见 [ADR-0005](../adr/0005-map-database-listeners-by-installation-path.md)。

### 展示

- 数据库使用独立页面，顶部指标分别展示数据库类别数、已发现类别数、正在监听类别数和未发现类别数。
- 固定按 PostgreSQL、MySQL、MariaDB、MongoDB、Redis 顺序展示五张卡片，摘要显示安装数和正在监听数。
- 卡片复用 Runtime 的折叠与展开交互：同时只展开一张，默认最多展示前 3 个 Database Installation，存在更多安装时才提供“查看全部”。
- “正在监听”使用绿色；“未发现”和“未监听”是中性灰色，不产生 Scan Notice；发现或监听状态未知以及读取失败使用橙色并产生 Scan Notice。
- 数据库监听进程仍保留在完整的“本地服务”区域；进程真实路径只用于 Database Installation 发现与匹配，不增加到 Local Service 行。
- Database Installation 的发现、版本和来源只随应用启动扫描和手动“重新扫描”更新；Dynamic Status Refresh 只重新计算已知安装的 Database Listening State。
- MongoDB 与 Redis Database Installation 扩展引入时使用 `schemaVersion = 11`；V1–V10 快照直接忽略并重新扫描，不增加快照迁移。

## TCP 监听服务扩展

- Environment Scan 固定执行 `/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -Fpcftn`，不调用 Shell、不接收用户参数、不请求管理员权限。
- 扫描保留进程名、PID、监听地址、端口和 IPv4/IPv6 地址族；同一 PID 聚合为一个 Local Service，完全相同的 Listener Binding 去重。Python 与 Node Local Service 还可保存 Local Service Attribution。
- loopback Listener Binding 不显示额外提示；wildcard 与非 loopback 绑定显示黄底感叹号，悬停时说明“可能可被局域网访问”。该范围只描述监听地址，不表示已验证防火墙或其他设备的实际可达性。
- Listener Binding 按端口、地址族、地址排序；Local Service 按最低端口、进程名、PID 排序。
- Machine Snapshot 编码并恢复全部 Local Service；应用启动和手动重新扫描沿用整份快照刷新并持久化，Dynamic Status Refresh 只更新内存中的 Local Service。
- 监听命令失败或超时时，本次 Local Service 结果为空并产生一条 Scan Notice；系统、Homebrew Availability、PATH、Runtime Installation 和可用的部分快照不受影响。
- 总览的“本地服务”区域展示服务数、端口数和全部 Listener Binding，并区分“当前没有可见监听项”和“监听读取失败”；扫描汇总增加本地服务组数，可能可被局域网访问的绑定按服务组加入现有通知入口，扫描时间和重新扫描操作保持不变。

### Python 与 Node 服务归属

- 只为进程名匹配 Python 或 Node 的 Local Service 识别归属，其他进程沿用既有展示。
- Python 从进程工作目录向上寻找最近的 `.git`、`pyproject.toml` 或 `package.json` 项目根。Node 同时识别包含当前工作目录的 Git 项目根和最近的 `package.json` 包根；没有 Git 项目时使用最近的包根。
- Python 项目名称优先读取项目根 `pyproject.toml` 的 PEP 621 `[project].name`。Node 的 Git 项目使用 Git 根目录名作为标题、最近的包根作为运行目录，例如标题 `personal-os`、目录 `~/Projects/personal-os/frontend`；没有 Git 项目时读取 `package.json.name` 并展示包根。名称缺失或不可读时使用对应根目录名。
- 没有项目证据时，若进程可执行文件位于 `.app` 包内，则以该 App 名称和包路径作为归属；否则保留 Python 或 Node 的通用运行时名称。
- 显示优先级为“项目 → App → 运行时”。项目卡片保留 Python 或 Node 图标并展示缩写项目根路径，App 卡片使用 App 图标；归属不同的 Local Service 不合并为同一展示组。
- 归属扫描不读取或保存完整命令行，不遍历父进程，不按 API、端口或参数猜测。工作目录、项目文件或可执行路径读取失败时静默回退，不产生新的 Scan Notice。
- Machine Snapshot 使用 `schemaVersion = 12` 编码 Local Service Attribution；V1–V11 快照直接忽略并重新扫描。

完整取舍见 [ADR-0006](../adr/0006-attribute-runtime-services-by-working-directory-and-app-path.md)。

2026-08-23 普通权限真机验收：Debug App 快照记录 11 个 Local Service、24 个 Listener Binding，与紧接着执行的同一固定 `lsof` 命令逐项一致，未发现普通权限造成的重要监听项缺失；未使用管理员重扫。

## Dynamic Status Refresh

- 默认启用定时刷新，前台间隔为 10 秒，后台间隔为 60 秒；切回前台时立即刷新一次。非活动、最小化和隐藏状态均使用后台间隔。
- 设置入口固定在侧边栏左下角。前台间隔可设为 5–300 秒，后台间隔可设为 30–3600 秒，且后台不得短于前台；关闭开关时保留并置灰间隔值。
- 设置使用系统偏好跨重启保存。编辑期间只保留草稿，有修改时显示“保存”按钮；保存后立即应用并在启用状态下刷新一次。
- 离开存在未保存修改的设置页时显示带关闭按钮的确认弹窗，提供“保存并离开”和“放弃修改”；关闭弹窗继续编辑。直接退出应用放弃草稿。
- Dynamic Status Refresh 复用 Local Service 的固定只读扫描，只更新 Local Service 及已知 Database Installation 的 Database Listening State；不发现安装、不读取版本、不调用其他 Provider、不写入 Machine Snapshot。
- 刷新失败时保留上一次成功结果并显示横幅，下一次成功后清除。数据库与本地服务页面显示最近一次成功动态刷新时间；总览的“最近扫描”仍表示完整 Environment Scan。
- 新出现的局域网暴露 Listener Binding 点亮通知红点；相同结果不重复标记未读，消失的结果直接从通知中移除。

完整取舍见 [ADR-0007](../adr/0007-refresh-dynamic-listening-status.md)。

## 验收场景

- 首次启动且没有持久化文件：自动扫描并显示当前结果，成功后写入最新快照。
- 已有快照再次启动：先可读取旧快照，自动扫描成功后替换为新快照。
- 已有快照但自动扫描失败：继续展示旧快照，并明确标记其扫描时间和更新失败原因。
- Lua 未安装：Lua 显示“未发现”，其他结果正常保存。
- 单个 Runtime 命令超时：该项显示“读取失败”，其他扫描继续。
- Homebrew 不在标准路径：显示“未发现”，不执行 Shell 配置。
- `PATH` 中存在多个 Git：只展示顺序最靠前的可执行文件及其版本。
- Git 未发现：Git 卡片显示中性“未发现”，不产生 Scan Notice。
- Git 版本命令失败、输出不可识别或超时：Git 卡片保留调用路径并显示“读取失败”，只产生一条 Git CLI Scan Notice，其他扫描结果仍可保存。
- User Git Configuration 全部缺失：展开 Git 卡片显示“未配置默认身份”、中性“未配置”默认分支和 Git 默认 User Excludes File，不产生 Scan Notice。
- User Excludes File 不存在：保留其标准化绝对路径、来源和“文件不存在”状态，不读取内容且不产生 Scan Notice。
- User Git Configuration 命令失败或超时：跳过配置详情并只产生一条清晰的 Scan Notice，Git CLI 与其他 Machine Environment 结果仍可保存。
- Git LFS 成功、缺失或版本读取失败：展开 Git 卡片分别显示版本、中性“未发现”或“读取失败”；只在失败时产生 Scan Notice。
- 签名配置全部缺失：展开 Git 卡片的四个白名单项均显示“未配置”，不枚举或验证任何密钥。
- 多个 Credential Helper：按 Git 配置顺序展示；helper 参数、自定义命令正文及其中的敏感文本不进入 Machine Snapshot 或编码后的 JSON。
- 签名或 Credential Helper 配置读取失败：只隐藏对应详情并产生一条 Scan Notice，其他 Git 与 Machine Environment 事实仍可保存。
- GitHub 本地配置、`GH_TOKEN` 或 `GITHUB_TOKEN` 存在：Git 卡片只显示对应来源“已配置”，Machine Snapshot 与 JSON 不包含账号或 token 值。
- Git 或 GitHub CLI 缺失：GitHub Authentication Configuration 仍独立显示；`gh` 缺失与 `git_protocol` 缺失均保持中性且不产生 Scan Notice。
- GitHub CLI 配置命令失败或超时：保留本地文件和进程级认证来源事实，只产生一条 GitHub CLI Configuration Scan Notice，其他结果仍可保存。
- 主机基础信息无法建立：显示整体错误，磁盘中的上一份快照保持不变。
- 快照文件损坏或版本不支持：忽略旧文件并执行启动扫描。
- `PATH` 依次包含 Python 3.12 和 3.9：两项均展示，3.12 标记“当前生效”，Runtime 行和扫描提示显示“PATH 版本冲突”。
- pyenv 安装 Python 3.11 和 3.12、当前只激活 3.12：两项均展示，3.11 不构成 Runtime Conflict。
- 同一 Runtime Installation 经软链接、`PATH` 和 Runtime Provider 重复发现：合并为一项，同时展示调用路径和不同的实际路径。
- `PATH` 首个 Runtime Installation 启动失败、第二个可用：首项仍标记 Effective 并显示“版本读取失败”。
- Provider 超时：保留其他来源的安装，扫描提示记录对应 Provider 失败。
- Provider 返回的可执行文件不可用：保留版本和预期绝对路径并显示错误。
- 同一 PostgreSQL 可执行文件经 `PATH`、Homebrew 和 Local Service 重复发现：合并为一个 Database Installation 并显示“正在监听”。
- 安装两个 PostgreSQL 版本且只有一个实际路径正在监听：只标记该 Database Installation，不连带标记另一个版本。
- MySQL 与 MariaDB 的普通或带版本后缀 Homebrew formula 经三个来源重复发现：分别按真实可执行文件目标去重并精确匹配监听版本。
- MongoDB Community 与 Redis 的普通或带版本后缀 Homebrew formula 经三个来源重复发现：分别按 `mongod` 与 `redis-server` 的真实可执行文件目标去重并精确匹配监听版本。
- 只由 Local Service 发现的 `mysqld` 无法通过版本输出区分 MySQL 与 MariaDB：不创建 Database Installation，保留 Local Service 并产生 Scan Notice。
- `mariadbd` 版本读取失败：保留已确定为 MariaDB 的 Database Installation 和精确监听状态，并产生 Scan Notice。
- 发现 Homebrew 数据库但没有匹配 Local Service：显示“未监听”，不产生 Scan Notice。
- Homebrew Database Provider 失败且没有其他发现结果：显示“发现状态未知”并产生 Scan Notice，不显示“未安装”。
- Local Service 扫描失败或已识别数据库进程的真实路径不可读：相关 Database Listening State 显示“监听状态未知”。
- Python 服务工作目录位于带 PEP 621 名称的项目内：卡片显示项目名、Python 项目服务和缩写项目根路径。
- Node 服务工作目录位于 Git 项目的子目录包内：卡片显示 Git 根目录名、Node.js 项目服务和缩写 Git 根路径；例如 `personal-os/frontend` 显示 `personal-os`。
- Node 服务不位于 Git 项目但工作目录位于带 `package.json.name` 的项目内：卡片显示该包名和缩写项目根路径。
- Python 或 Node 服务同时具有项目工作目录和 `.app` 内可执行文件：优先显示项目归属。
- Python 服务没有项目证据但可执行文件位于 `oMLX.app`：卡片显示 `oMLX` 并使用 App 图标。
- 归属所需路径或项目文件不可读：不显示归属、不增加 Scan Notice，继续显示通用 Python 或 Node 服务。
- 非 Python/Node Local Service：不识别项目或 App 归属，保持既有名称、图标和分组规则。
- 只启用 Unix Socket 或位于容器内的 PostgreSQL：不标记为 Listening Database Installation；容器端口代理仍可作为 Local Service 展示。
- 读取 V1–V4 快照：忽略旧快照并执行扫描，成功后写入 V5 快照。
- 读取 V1–V5 快照：忽略旧快照并执行扫描，成功后写入 V6 快照。
- 读取 V1–V6 快照：忽略旧快照并执行扫描，成功后写入 V7 快照。
- PostgreSQL Database Installation 纵向基线读取 V1–V8 快照：忽略旧快照并执行扫描，成功后写入 V9 快照。
- MySQL 与 MariaDB Database Installation 扩展读取 V1–V9 快照：忽略旧快照并执行扫描，成功后写入 V10 快照。
- MongoDB 与 Redis Database Installation 扩展读取 V1–V10 快照：忽略旧快照并执行扫描，成功后写入 V11 快照。
- Local Service Attribution 扩展读取 V1–V11 快照：忽略旧快照并执行扫描，成功后写入 V12 快照。
- 受支持 Terminal Application 未安装：Terminal 卡片显示“未发现”，不产生 Scan Notice；已发现应用按固定支持清单展示名称、版本和路径。
- Default Login Shell 未注册或不可执行：Shell 卡片仍将其置顶并标记“不可用”，同时产生 Scan Notice；其他可用项保持 `/etc/shells` 顺序。
- `/etc/shells` 或 POSIX 账户记录读取失败：保留另一来源可建立的 Shell 结果，并分别产生一条 Scan Notice。
- Terminal Application 与 Shell Installation 扩展读取 V1–V12 快照：忽略旧快照并执行扫描，成功后写入 V13 快照。

## 相关决策

- [ADR-0001：不启用 App Sandbox](../adr/0001-run-without-app-sandbox.md)
- [ADR-0002：只读扫描并持久化最新环境快照](../adr/0002-read-only-environment-scan-snapshot.md)
- [ADR-0003：按 PATH 与 Provider 分层发现 Runtime](../adr/0003-source-aware-runtime-discovery.md)
- [ADR-0004：Environment Scan 保持本地观察](../adr/0004-keep-environment-scan-local.md)
- [ADR-0005：按安装路径映射数据库 TCP 监听状态](../adr/0005-map-database-listeners-by-installation-path.md)
- [ADR-0006：按工作目录与 App 路径识别运行时服务归属](../adr/0006-attribute-runtime-services-by-working-directory-and-app-path.md)
- [ADR-0007：定时刷新动态监听状态](../adr/0007-refresh-dynamic-listening-status.md)
