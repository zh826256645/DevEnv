# DevEnv

> A developer environment manager for macOS.

DevEnv 是一个面向 macOS 开发者的本地开发环境管理工具。

它希望成为：

> **macOS 开发环境的「系统设置」**

DevEnv 不尝试重新发明 Homebrew、mise、uv、Docker 等工具，而是在这些成熟工具之上提供统一的扫描、管理、诊断和可视化能力。

## 当前进度

截至 2026-08-25：

- 已完成 macOS 系统、系统卷、Homebrew、PATH 与常见语言 Runtime 的只读扫描和最新快照持久化。
- 已完成 Homebrew、mise、nvm、uv、pyenv、macOS `java_home`、rustup 与 rbenv 的多来源 Runtime Installation 发现。
- 已完成普通用户权限可见的 TCP 监听服务、绑定地址与监听范围提示。
- 已完成当前 `PATH` 首个生效 Git CLI、Git LFS、用户级配置与脱敏后的 GitHub Authentication Configuration 只读扫描。
- 已完成受支持 Terminal Application 与注册 Shell Installation、Default Login Shell 的只读扫描。
- 已完成总览、Runtime、数据库和本地服务侧边栏页面，以及按需展开详情、通知与状态说明等原生 SwiftUI 界面。
- 已完成扫描器测试、集成验收、ADR 与界面设计决策记录。
- v0.1 与 v0.2 的只读扫描范围已交付；Git Tooling State 已交付 Git CLI、Git LFS、脱敏后的 User Git Configuration 与 GitHub Authentication Configuration。

Docker、服务管理、端口管理、环境修改和诊断仍属于后续规划；现有 Environment Scan 保持只读。

你可以通过 DevEnv 快速了解：

* 当前 Mac 安装了哪些开发环境
* Node.js / Python / Go / Java 等运行时来自哪里
* 当前有哪些本地服务正在运行
* 哪些端口正在被占用
* 是否存在多个版本或 PATH 冲突
* 某个项目需要什么开发环境
* 为什么一个项目无法正常运行
* 如何将当前开发环境迁移到另一台 Mac

---

## ✨ Features

### Environment Overview

统一查看当前 Mac 的开发环境状态：

```text
System
macOS
Apple Silicon

Runtime
✓ Node.js       24.6.0
✓ Python        3.13.5
✓ Go            1.25
✓ Java          24
✓ Rust          1.89

Services
● PostgreSQL    :5432
● Redis         :6379
○ MySQL         stopped

Containers
● Docker        Running

Network
Proxy           127.0.0.1:7890
Ports           12 listening
```

---

### Runtime Management

发现并管理常见开发语言运行时：

* Node.js
* Python
* Go
* Java
* Rust
* Ruby

DevEnv 不只显示版本，还会尽可能识别运行时的来源：

```text
Node.js

Version
24.6.0

Binary
~/.local/share/mise/installs/node/24.6.0/bin/node

Managed By
mise
```

帮助你回答：

> 这个 Node 到底是哪里装的？

---

### Homebrew

集成 Homebrew 环境信息：

* Formula
* Cask
* Installed Packages
* Outdated Packages
* Homebrew Services

例如：

```text
PostgreSQL 17     Installed
Redis 8           Installed
Nginx             Outdated
```

DevEnv 本身不会代替 Homebrew，而是将 Homebrew 作为底层 Provider。

---

### Services

统一管理本地开发服务：

```text
PostgreSQL       ● Running     :5432
Redis            ● Running     :6379
MySQL            ○ Stopped
Nginx            ● Running     :80
```

支持：

* 查看状态
* Start
* Stop
* Restart
* 查看日志
* 查看监听端口

---

### Projects

DevEnv 可以扫描本地开发项目，并识别项目所需要的开发环境。

例如：

```text
my-api/
├── pyproject.toml
├── .python-version
└── docker-compose.yml
```

DevEnv 可以识别：

```text
Python        3.13
PostgreSQL    Required
Redis         Required
Docker        Required
```

并与当前环境进行比较：

```text
Project Environment

✓ Python 3.13 installed
✓ PostgreSQL running
✗ Redis stopped
✓ Docker running
```

未来可以通过：

```text
Start Environment
```

一键准备项目所需的开发环境。

---

## 🩺 Environment Diagnostics

DevEnv 的一个核心目标是帮助开发者发现环境问题。

例如：

```text
Environment Health

PATH
✓ OK

Node.js
⚠ 3 installations found

Python
⚠ Multiple Python environments detected

Homebrew
✓ Apple Silicon installation

Docker
✓ Running

Ports
⚠ Port 5432 is occupied by PostgreSQL
```

未来 DevEnv 将能够检测：

* PATH 配置错误
* PATH 重复
* 多个 Node.js 安装
* 多个 Python 安装
* Intel / Apple Silicon Homebrew 混用
* Shell 配置冲突
* 无效环境变量
* 端口冲突
* 已停止但项目依赖的 Service
* Docker 状态异常
* 失效的软链接
* Runtime 版本不匹配

---

## 🤖 AI Environment Doctor

未来计划加入 AI 环境诊断能力。

DevEnv 可以将：

* 当前开发环境
* Runtime 信息
* PATH
* Shell 配置
* 服务状态
* 端口状态
* 项目配置
* Terminal 错误

统一转换成结构化上下文。

AI 可以帮助开发者回答：

```text
为什么 npm 使用的 Node 版本和 node -v 不一样？
```

或者：

```text
为什么这个 FastAPI 项目启动失败？
```

AI 会分析本机环境，并生成修复建议。

所有修改操作都应该：

> **先展示，再执行。**

避免 AI 未经确认直接修改用户开发环境。

---

## 📦 Environment Profiles

未来 DevEnv 可以通过 Profile 描述一套完整开发环境。

例如：

```yaml
name: backend-development

runtimes:
  node: "24"
  python: "3.13"
  go: "1.25"

services:
  postgresql: "17"
  redis: "8"

apps:
  - visual-studio-code
  - orbstack
  - tableplus

configs:
  - ~/.gitconfig
  - ~/.zshrc
  - ~/.ssh/config
```

用户可以：

```text
Export Environment
```

然后在新的 Mac 上：

```text
Import Environment
```

快速恢复开发环境。

---

## 🖥 UI

DevEnv 使用原生 macOS UI。

计划中的主要页面：

```text
Overview

Projects

Runtimes
├── Node.js
├── Python
├── Go
├── Java
└── Rust

Services

Containers

Network

Config

Diagnostics

Snapshots

Settings
```

设计目标：

* Native macOS
* 简洁
* 快速
* 不干扰现有开发工具
* 尽可能少的学习成本

---

## 🏗 Architecture

DevEnv 采用 Provider 架构。

```text
DevEnv.app
│
├── UI
│
├── EnvironmentCore
│   ├── Scanner
│   ├── CommandRunner
│   ├── Diagnostics
│   ├── ProfileEngine
│   └── StateStore
│
├── Providers
│   ├── HomebrewProvider
│   ├── MiseProvider
│   ├── UVProvider
│   ├── DockerProvider
│   ├── GitProvider
│   ├── ShellProvider
│   └── LaunchdProvider
│
└── Persistence
```

DevEnv 负责：

```text
Discover
    ↓
Parse
    ↓
Normalize
    ↓
Display
    ↓
Execute
    ↓
Verify
```

底层真正的软件管理仍然由成熟工具完成。

例如：

```text
DevEnv
  │
  ├── Homebrew
  ├── mise
  ├── uv
  ├── Docker
  ├── Git
  └── launchd
```

---

## 🔌 Provider

不同开发工具通过 Provider 接入。

概念接口：

```swift
protocol EnvironmentProvider {

    func detect() async throws -> ProviderStatus

    func listInstalled() async throws -> [DevPackage]

    func install(_ package: DevPackage) async throws

    func uninstall(_ package: DevPackage) async throws

    func update(_ package: DevPackage) async throws
}
```

例如：

```text
HomebrewProvider

MiseProvider

UVProvider

DockerProvider

GitProvider
```

这种设计可以让 DevEnv 很容易扩展新的开发工具。

---

## ⚙️ Command Runner

所有 Shell 操作统一通过 Command Runner 执行。

```text
Command
│
├── executable
├── arguments
├── environment
├── workingDirectory
└── requiresPrivilege
        │
        ▼
CommandRunner
        │
        ├── stdout
        ├── stderr
        └── exitCode
```

这样可以统一实现：

* 实时日志
* 命令取消
* 错误处理
* 执行记录
* 权限管理
* 操作审计

---

## 🔐 Security

开发环境管理工具不可避免地需要执行本地命令。

DevEnv 的安全原则：

### Never hide commands

用户应该能够知道 DevEnv 即将执行什么。

例如：

```bash
brew services start redis
```

### Confirm destructive operations

以下操作执行前必须明确确认：

* 删除软件
* 删除环境
* 修改系统配置
* 修改 Shell 配置
* 修改 `/etc/hosts`
* 删除 Docker 数据
* 删除开发环境文件

### Least privilege

普通操作不使用管理员权限。

需要系统权限的能力应该通过独立的 Privileged Helper 实现，而不是在程序内部大量执行：

```bash
sudo ...
```

---

## 🛠 Tech Stack

DevEnv 计划采用：

* Swift
* SwiftUI
* Swift Concurrency
* SwiftData / SQLite
* macOS Process
* Security Framework
* ServiceManagement Framework

目标平台：

```text
macOS
Apple Silicon first
```

后续根据需要支持 Intel Mac。

---

## 🚧 MVP

第一阶段不会尝试管理所有开发工具。

### v0.1（已完成）

只包含以下已交付的只读 Environment Scanner 能力：

* [x] macOS 系统与系统卷只读扫描
* [x] 最新 Machine Snapshot 持久化
* [x] PATH 与 Homebrew Availability 扫描
* [x] Node.js、Python、Go、Java、Rust、Ruby 与 Lua 扫描
* [x] Runtime Installation 版本、路径、来源与多版本展示
* [x] Effective Runtime Installation 与 Runtime Conflict 识别
* [x] 原生 SwiftUI 总览、Scan Notice 与重新扫描

v0.1 范围已冻结；新增能力进入后续里程碑。

---

## 🗺 Roadmap

### v0.1

**Environment Scanner（已完成）**

以只读方式扫描系统、Homebrew、PATH 与 Runtime Installation，并持久化最新 Machine Snapshot。

解决：

> 我的电脑现在到底有什么？

---

### v0.2

**Services & Ports**

以只读方式展示：

* TCP 监听端口
* 监听进程与 PID
* 仅本机或可能对局域网开放的监听范围
* 端口扫描失败产生的 Scan Notice

不包含 Start、Stop、Restart、Kill 或其他 Machine Environment 修改能力。

解决：

> 当前有哪些本地服务正在运行，监听了哪些端口？

---

### Git Tooling State

**Git Tooling State（已完成）**

按当前 `PATH` 顺序展示首个生效 Git CLI、Git LFS 与 GitHub CLI 的本地 `git_protocol`；展开 Git 卡片可查看用户级 Default Git Identity、默认分支、User Excludes File、签名配置、脱敏后的 Credential Helper Chain，以及 GitHub 本地/进程级认证来源是否已配置。Environment Scan 不联网验证认证，不读取或持久化账号名、token、配置文件内容、密钥、helper 参数或自定义命令正文。结果随最新 Machine Snapshot 持久化。

解决：

> 当前 App 运行用户实际会调用哪个 Git？

> 没有具体仓库上下文时，Git 默认使用什么身份、分支与跨仓库忽略文件？

> 用户级签名开关与 Credential Helper Chain 当前如何配置？

> GitHub CLI 是否存在本地或进程级认证来源，当前使用哪种 Git 协议？

---

### Terminal & Shell

**Terminal Application 与 Shell Installation（已完成）**

通过 Launch Services 展示受支持的 Terminal Application 名称、版本与路径；通过 `/etc/shells` 和当前用户账户记录展示注册 Shell Installation 与 Default Login Shell。扫描不推断默认或当前 Terminal Session，不加载 Shell 配置，也不启动 Shell 读取版本。

解决：

> 当前 Mac 安装了哪些受支持的终端应用，当前账户默认使用哪个登录 Shell？

---

### v0.3

**Environment Manager**

支持：

* Runtime 管理
* Homebrew 管理
* Service 管理
* Docker 管理

解决：

> 我的开发环境怎么管理？

---

### v0.4

**Projects**

自动识别：

* `package.json`
* `.node-version`
* `.nvmrc`
* `.tool-versions`
* `mise.toml`
* `pyproject.toml`
* `.python-version`
* `go.mod`
* `Cargo.toml`
* `docker-compose.yml`
* `compose.yml`

解决：

> 这个项目需要什么环境？

---

### v0.5

**Environment Diagnostics**

提供环境健康检查和冲突分析。

解决：

> 为什么我的环境有问题？

---

### v0.6

**Profiles & Snapshots**

支持：

```text
Export
Import
Snapshot
Restore
```

解决：

> 换 Mac 后怎么恢复开发环境？

---

### v1.0

**AI Environment Doctor**

AI 根据本机真实环境进行问题诊断。

解决：

> 为什么我的项目跑不起来？

---

## 🎯 Philosophy

DevEnv 不想成为：

> Another package manager.

也不想成为：

> Another terminal wrapper.

DevEnv 想解决的是开发环境长期存在但一直非常碎片化的问题。

开发者通常需要同时理解：

```text
Homebrew
mise
nvm
pyenv
uv
Docker
launchd
PATH
Shell
Ports
Environment Variables
Project Config
```

而 DevEnv 希望在这些工具之上提供一个统一的视角：

> **One place to understand your Mac development environment.**

---

## 💡 Why DevEnv?

随着开发工具越来越多，一个 Mac 上可能同时存在：

```text
Node from Homebrew

Node from mise

Node from nvm

Python from macOS

Python from Homebrew

Python from uv

Python from pyenv
```

最终问题往往不是：

> 软件有没有安装？

而是：

> **当前真正生效的是哪一个？**

DevEnv 希望帮助开发者理解、管理并最终掌控自己的开发环境。

---

## 🤝 Contributing

DevEnv 目前处于早期开发阶段。

欢迎提交：

* Issue
* Feature Request
* Bug Report
* Pull Request
* Provider Implementation
* UI / UX Suggestions

如果你使用某种开发环境管理工具，也欢迎提出新的 Provider 支持建议。

---

## 📄 License

License TBD.

---

<p align="center">
  <b>DevEnv</b>
  <br />
  Understand your development environment.
</p>
