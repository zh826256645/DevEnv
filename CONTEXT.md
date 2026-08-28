# DevEnv

DevEnv 帮助 macOS 开发者理解本机的开发工具状态，并将其与项目要求或期望配置区分开。

## Language

**Machine Environment**:
当前 App 运行用户在一台 Mac 上可观察、可调用的开发工具、运行时和服务的实际状态。
_Avoid_: Environment, Development Environment

**Project Requirements**:
一个项目声明的系统条件、运行时、开发工具、外部服务或容器运行条件，而不是本机的实际状态；库依赖本身不作为 Project Requirement，但直接声明的数据库客户端库可以作为 Project Database Requirement 的推定证据。
_Avoid_: Project Environment

**Project Database Requirement**:
一个 Project Component 直接声明或由直接依赖的已知数据库客户端库推定的数据库服务端软件类型与可选版本约束；客户端库版本以及动态或未解析的服务端版本均不构成服务端版本约束，也不从传递依赖推定。是否满足只取决于匹配的 Database Installation，Database Listening State 仅作为补充证据，不表示连接、鉴权、Schema 或数据库健康。
_Avoid_: Database Health Requirement, Database Availability Requirement

**MySQL-compatible Database Requirement**:
由同时适用于 MySQL 与 MariaDB 的直接客户端依赖推定的 Project Database Requirement；任一类型的 Database Installation 均可满足它，明确声明的 MySQL 或 MariaDB 要求仍保持各自类型。
_Avoid_: MySQL Requirement, MariaDB Requirement

**Project Root**:
一个项目的规范目录边界：优先采用包含所选目录的最近 Git 根；没有 Git 时，由项目清单或用户直接选择确定。嵌套 Git 根和用户明确选择的嵌套边界各自形成 Project Root，父项目不吸收其清单。
_Avoid_: Package Root, Working Directory

**Project Record**:
DevEnv 对一个已发现 Project Root 保存的轻量身份记录；原目录暂时不可用时记录仍可保留，删除记录不会删除或修改原目录。
_Avoid_: Project Snapshot, Project Files

**Project Run Configuration**:
DevEnv 保存、归属于一个 Project Record 的运行意图，包含稳定身份、名称、命令、Project Root 相对工作目录和可选来源身份；它不是 Project Requirement 或 Project Requirements Summary，不表示项目可运行，也不执行命令。
_Avoid_: Project Requirement, Project Requirements Summary, Runnable Status

**Project Run Suggestion**:
DevEnv 从项目声明中只读识别、可由用户选择保存为 Project Run Configuration 的候选运行意图；它不会自动执行，也不表示项目可信或可运行。
_Avoid_: Auto Run, Project Requirement, Runnable Status

**Project Run Session**:
用户从已保存的 Project Run Configuration 显式启动、仅存在于当前 App 进程中的交互式 PTY 会话；它保留本次进程状态、内存中的终端输出和退出码，但不持久化为 Project Record 或 Machine Snapshot。
_Avoid_: Shell Session, Terminal Application, Machine Snapshot

**Ignored Project**:
用户从 DevEnv 删除后不再由 Project Search Root 自动恢复的 Project Root；直接重新添加该目录或由用户恢复时解除忽略。
_Avoid_: Deleted Project, Unavailable Project

**Project Component**:
Project Root 内由自身目录中的项目清单声明独立 Project Requirements 的组成部分；这些声明会在 Project Root 层按 Machine Environment 能力归并，同类 Runtime 的不相容版本形成 Project Requirement Conflict。
_Avoid_: Project, Package

**Project Capability Requirement**:
一个 Project Root 内对同一项 Machine Environment 能力的全部 Project Requirements 归并结果；它保留每条声明来源，并以一个 Requirement Satisfaction State 表示项目级匹配结论。数据库裸版本取最低声明版本作为最低门槛，其他版本约束必须能够同时满足。
_Avoid_: Merged Requirement, Requirement Card

**Project Requirement Conflict**:
同一 Project Root 对同一项 Machine Environment 能力存在无法按该能力的归并规则得到可满足版本的多份声明。
_Avoid_: Runtime Conflict, Version Conflict

**Project Notice**:
项目发现或 Project Requirements 读取中的失败与不确定性，只影响对应 Project Search Root、Project 或 Project Component，不属于 Environment Scan 的 Scan Notice。
_Avoid_: Scan Notice, Project Error, Health Problem

**Requirement Satisfaction State**:
Project Requirement 与 Machine Environment 比较后的证据状态，取值为“已满足”“未满足”“无法判断”或“声明冲突”；它不保证项目一定能够运行。
_Avoid_: Project Health, Runnable Status, Compatibility Result

**Project Requirements Summary**:
一个 Project Record 对其 Project Requirements 比较结果的汇总，取值为“已满足”“未满足”“无法判断”“声明冲突”“未声明要求”或“不可用”；它不是项目健康或可运行性结论。
_Avoid_: Project Health, Runnable Status

**Project Search Root**:
用户明确选择、供 DevEnv 在一次操作中于其边界内递归发现 Project Root 的临时目录；它本身不一定是项目，也不由 DevEnv 持久化。
_Avoid_: Project Root, Workspace, Scan Directory

**Environment Profile**:
一套可移植的目标配置，描述期望存在的开发工具状态。
_Avoid_: Environment

**Environment Scan**:
对当前 Mac 的 Machine Environment 进行一次只读观察，形成可展示的状态结果。
_Avoid_: Environment Check, Health Check

**Dynamic Status Refresh**:
在不重新发现安装、不更新版本且不持久化 Machine Snapshot 的前提下，只重新观察 Local Service，并据此更新已知 Database Installation 的 Database Listening State。
_Avoid_: Environment Scan, Full Scan, Database Discovery

**Scan Notice**:
Environment Scan 发现的读取失败、不可用安装或状态冲突，表示值得用户查看，但不等同于系统故障或健康诊断。
_Avoid_: Issue, Error, Health Problem

**Machine Snapshot**:
一次 Environment Scan 产生的、描述主机基础信息与当前 App 运行用户可见开发工具状态的结果。
_Avoid_: Environment, System Profile

**Package Manager Tool**:
当前 App `PATH` 对 uv、Bun、npm、pnpm 或 Yarn 首先解析到的可执行工具，包含调用路径、可确认的实际路径、版本和读取状态；它不枚举未进入 `PATH` 的其他安装。
_Avoid_: Runtime Installation, Package, Package Manager Environment

**Corepack Proxy Configuration**:
当前 `PATH` 已存在指向 Corepack 的 pnpm 或 Yarn 代理；Environment Scan 只记录已配置事实和路径，不执行代理获取版本，也不触发下载或激活。
_Avoid_: Installed Package Manager, Available Version

**Project Package Manager Requirement**:
Project Component 从显式工具声明、受支持的版本字段或单一锁文件得到的 Package Manager Tool 要求；显式选择优先，同一 Project Component 内来源无法唯一确定时产生 Project Notice 而不猜测。
_Avoid_: Dependency Requirement, Lockfile Version

**Terminal Application**:
当前 App 运行用户在该 Mac 上可发现的、提供交互式终端界面的已安装应用；不表示启动 DevEnv 的终端会话。
_Avoid_: Terminal Session, Current Terminal, 终端会话

**Shell Installation**:
当前 App 运行用户在该 Mac 上可选择为登录 Shell，或已被当前账户配置为 Default Login Shell 的命令解释器实例；配置项可能因未注册或不可执行而不可用。
_Avoid_: Shell Session, Shell Configuration

**Default Login Shell**:
当前 App 运行用户的账户记录指定为登录后默认启动的 Shell 路径；该路径可能无法解析为可用的 Shell Installation，也不表示当前存在 Shell 会话。
_Avoid_: Current Shell, Active Shell

**Runtime Installation**:
本机可被发现的某个语言运行时实例，包含其版本与来源位置。
_Avoid_: Runtime, Package

**Project-local Runtime Installation**:
位于特定 Project Component 内、只在该项目上下文中发现和使用的 Runtime Installation；它可以作为该 Component 的要求满足证据，但不进入全机 Runtime 列表。
_Avoid_: Virtual Environment, Global Runtime

**Database Installation**:
本机可被发现的某个数据库服务端软件安装实例，包含数据库类型、版本与服务端可执行文件路径。
_Avoid_: Database, 数据库, DB

**Listening Database Installation**:
服务端可执行文件实际路径与至少一个 Local Service 匹配的 Database Installation；该状态只说明存在 TCP Listener Binding，不覆盖仅使用 Unix Socket 的运行形态，也不表示数据库健康或可用。
_Avoid_: Running Database, Healthy Database, Available Database, Active Database

**Database Listening State**:
Environment Scan 对某个 Database Installation 是否能精确匹配 TCP 监听进程的观察结果，取值为“正在监听”“未监听”或“监听状态未知”。
_Avoid_: Database Run State, Health Status

**Database Discovery State**:
Environment Scan 对 Database Installation 发现完整性的观察结果，取值为“已发现”“未发现”或“发现状态未知”；该状态不证明软件在本机上绝对存在或不存在。
_Avoid_: Installation State, Installed Status

**Database Provider**:
从已知工具、平台索引或 Local Service 的真实可执行文件路径中，发现未进入当前 `PATH` 的 Database Installation 的来源。
_Avoid_: Database Scanner, Database Manager

**Runtime Provider**:
从已知工具或平台索引中发现未进入当前 `PATH` 的 Runtime Installation 的来源。
_Avoid_: Scanner, Version Manager

**Runtime Installation Source**:
Environment Scan 能够确认的 Runtime Installation 管理或发现来源；它与该安装是否进入 `PATH`、是否当前生效无关，不声称还原历史安装操作。
_Avoid_: Installation Method, Runtime State

**Local Service**:
当前 App 运行用户可见、按 PID 聚合且至少具有一个 TCP Listener Binding 的本机进程。
_Avoid_: Daemon, Background Service

**Local Service Attribution**:
Environment Scan 对 Python 或 Node Local Service 所属开发项目或宿主 App 的识别结果；没有充分本机证据时为空。
_Avoid_: API Name, Process Owner, Service Guess

**Listener Binding**:
Local Service 监听 TCP 连接的地址、端口和地址族组合。
_Avoid_: Port, Endpoint

**Effective Runtime Installation**:
当前 `PATH` 对某类语言运行时优先解析到的 Runtime Installation。
_Avoid_: Current Runtime, Active Runtime

**Runtime Conflict**:
同类语言运行时在当前 `PATH` 中存在多个版本不同的 Runtime Installation，因 `PATH` 顺序可能产生不同解析结果的状态。Provider 发现但未进入 `PATH` 的安装不构成冲突。
_Avoid_: Version Conflict, PATH Error

**Homebrew Availability**:
Homebrew 在当前 Mac 上是否可调用，以及可识别的安装位置。
_Avoid_: Homebrew Environment

**Homebrew Service**:
当前 Homebrew 中声明了后台服务、可由当前 App 运行用户管理的已安装 Formula；它可以处于已启动、未启动或异常状态，与当前具有 TCP Listener Binding 的 Local Service 不等同。
_Avoid_: Local Service, Homebrew Process, Background Process

**Homebrew-managed Database Installation**:
能够以确切 Formula 映射到 Homebrew Service 的 Database Installation；其 Homebrew Service 状态与 Database Listening State 是两个独立事实。
_Avoid_: Running Database, Managed Database, Database Service

**Git Tooling State**:
当前 App 运行用户在该 Mac 上生效的 Git CLI、User Git Configuration 及配套工具状态，不包含任何具体仓库的分支、远端或工作区状态。
_Avoid_: Git Environment, Git Health, Repository State

**User Git Configuration**:
当前 App 运行用户所拥有、独立于具体仓库生效的 Git 配置，不包含整机或仓库局部配置。
_Avoid_: Global Git Configuration

**Default Git Identity**:
User Git Configuration 在没有具体仓库上下文时用于标识提交作者的默认名称与邮箱，不包含条件式或仓库局部身份。
_Avoid_: Git Account, Git User

**User Excludes File**:
当前 App 运行用户用于跨仓库忽略路径的 Git 规则文件，其位置可来自 User Git Configuration 或 Git 的用户默认位置。
_Avoid_: Global .gitignore, Default Ignore File

**Git Signing Configuration**:
User Git Configuration 中用于选择签名格式、签名标识及提交和标签签名开关的本地事实，不表示签名密钥已经验证或可用。
_Avoid_: Verified Signing Identity, Signing Health

**Credential Helper Chain**:
User Git Configuration 中按配置顺序生效的凭据助手标识序列；不包含 helper 参数或自定义命令正文。
_Avoid_: Git Credentials, Credential Health

**GitHub Authentication Configuration**:
当前 App 运行用户存在可供 GitHub CLI 使用的本地或进程级认证来源，不表示凭据已经联网验证或当前处于登录状态。
_Avoid_: GitHub Login Status, Authenticated GitHub Account
