# DevEnv 发版流程

状态：已确认的规划；自动化尚未实现。

本文定义 DevEnv 从 `develop` 晋级到 `master`、生成安装产物并发布 GitHub Release 的可复用流程。首个适用版本是 `v0.1.0` Private Preview。

执行规划由 GitHub 原生父子任务和依赖关系跟踪：

- [v0.1.0 Milestone](https://github.com/zh826256645/DevEnv/milestone/1)
- [发布 v0.1.0 Private Preview（#68）](https://github.com/zh826256645/DevEnv/issues/68)
- [后续接入 Developer ID、公证与 Stapling（#77）](https://github.com/zh826256645/DevEnv/issues/77)

## 1. 版本定位

**Private Preview（私有预览版）**面向获得仓库访问权限的受邀测试者，不等同于稳定正式版。

`v0.1.0` 的发布边界：

| 项目 | 约定 |
| --- | --- |
| GitHub 仓库 | Private |
| GitHub Release | Prerelease |
| App 版本 | `0.1.0` |
| Build | `1` |
| 最低系统 | macOS 15.0 |
| 架构 | Apple Silicon `arm64`，不包含 `x86_64` |
| 签名 | 完整 ad-hoc App Bundle 签名 |
| Apple 公证 | 不执行 |
| 主产物 | `DevEnv-0.1.0-arm64.dmg` |
| 校验文件 | `DevEnv-0.1.0-arm64.dmg.sha256` |
| 自动更新 | 不提供 |

Private Preview 必须在 Release Notes 中明确说明：

- App 未使用 Developer ID 签名，也未经过 Apple 公证。
- Gatekeeper 阻止首次打开属于当前版本的已知分发限制。
- 测试者只应通过“系统设置 → 隐私与安全性”确认打开；不引导全局关闭 Gatekeeper，也不提供递归移除隔离属性的命令。
- 新版本通过 Private GitHub Release 手动下载，不提供 App 内更新。

## 2. 范围冻结与 Release Blocker

`v0.1.0` 以确认规划时的 `develop` 提交 `f9434dc` 为功能冻结基线。后续发版工程提交可以继续推进分支，但不得扩大产品功能范围；冻结后只允许：

- 修复 Release Blocker；
- 建立 CI、Release Runner、打包与发布自动化；
- 补充发版文档和 Release Notes；
- 修复自动化验证发现的阻塞问题。

以下问题属于 Release Blocker：

- XCTest、Release 构建或最终 DMG 校验失败；
- 已知会导致 App 崩溃的问题；
- Project Record 丢失，或 schema 1–4 无法按现有迁移语义升级；
- 未经用户确认执行项目命令；
- 无法安全停止已经可靠归属于 Project Run Session 的进程；
- 最低系统、CPU 架构、Bundle ID、版本号、Build 或 Tag 不一致；
- DMG 缺少 App、`Applications` 符号链接、可执行文件或必需资源；
- App Bundle 的 ad-hoc 签名或资源完整性校验失败。

普通 UI 瑕疵、非核心扫描缺失，以及能够被清楚解释的证据不足可以记录为 Known Limitations，不阻止 Private Preview。

## 3. 分支、版本与 Tag

### 3.1 分支晋级

- 日常业务代码直接在 `develop` 开发。
- 发版变更也先合入 `develop`。
- Release Blocker 清零后，通过一个 `develop → master` Pull Request 晋级发布内容。
- `master` 的目标合并提交是发布工作流唯一允许接受的正式目标 SHA。
- 不为 `v0.1.0` 增加 `release/*` 分支。

Private 免费仓库当前不能依赖 Branch Protection 或 Ruleset 强制门禁，因此发布工作流必须重新执行全部硬门禁，不能只信任 PR 页面状态。

### 3.2 版本来源

Xcode 项目中的以下值是版本元数据的唯一真相来源：

- `MARKETING_VERSION = 0.1.0`
- `CURRENT_PROJECT_VERSION = 1`

CI 不在构建时动态改写版本。正式发布工作流必须校验：

- 输入版本为 `0.1.0`；
- App 的 `CFBundleShortVersionString` 为 `0.1.0`；
- App 的 `CFBundleVersion` 为 `1`；
- Tag 名为 `v0.1.0`。

后续版本继续使用语义化版本号；Build 使用提交到 Xcode 项目中的单调递增整数。

### 3.3 Tag 策略

- 使用 annotated Tag。
- `v0.1.0` 必须指向已经通过发布门禁的 `master` SHA。
- 首版不把 GPG 或 SSH Tag 签名私钥引入 GitHub Actions。
- 工作流不得覆盖、移动或重新创建已经存在的同名 Tag。
- 正式工作流先创建 Tag，再创建 Draft Prerelease。
- 如果 Draft 被否决，不能移动 Tag；必须放弃该版本号并发布新的 Patch 版本。
- 已发布版本出现阻塞问题时，保留原 Tag 和审计记录，修复后发布新的 Patch 版本，例如 `v0.1.1`。

## 4. Runner 与工具链

### 4.1 日常 CI Runner

日常 CI 使用 GitHub Hosted macOS Runner，负责尽早发现测试和编译问题。它不是最终 arm64 发布产物的信任来源。

### 4.2 Release Runner

正式发布使用按需启停的专用 Apple Silicon Self-hosted Runner：

- 标签至少包含 `self-hosted`、`macOS`、`ARM64`、`release`；
- 只在 Dry Run 和正式发版窗口启动；
- 不作为长期在线的通用开发 Runner；
- 每次运行前确认工作目录干净、磁盘空间充足且没有残留挂载卷；
- 运行完成后停止 Runner，并清理包含未发布产物的工作目录。

Release Runner 固定：

- `Xcode 26.6`
- Build `17F113`

发布工作流开始时必须执行并校验 `xcodebuild -version`。不匹配时立即失败，不自动接受 Runner 当前默认 Xcode。

当前 Xcode 项目直接固定 SwiftTerm `1.11.2`。用于 CI 与发版的 `DevEnv.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` 必须在 #70 启用日常 CI 前纳入版本控制，并锁定其传递依赖 swift-argument-parser `1.8.2`；自锁文件提交起，依赖解析不得改写它。

### 4.3 Runner 生命周期操作手册

Runner 的首次注册、启动、停止、更新、发版前检查、发版后清理和故障恢复命令统一记录在 [Apple Silicon Release Runner 操作手册](release-runner.md)。核心约束如下：

- 常态下 Runner 服务停止，GitHub 页面显示 `Offline`；
- 发版窗口开始时启动服务并确认 `Idle`、四个标签、`arm64` 和 `Xcode 26.6 (17F113)`；
- 先运行 `.github/workflows/release-runner-validation.yml`，通过后才允许 Dry Run 或正式发布；
- 工作流预检至少要求 50 GiB 可用磁盘、干净 Checkout、无 DevEnv 残留挂载卷且 Runner 服务正在运行；
- 发版窗口结束后清理未发布产物并停止服务，不在宿主机长期保留日志、测试结果或 dSYM 副本；
- Runner 或工具链异常时不得改派到普通开发机或 GitHub Hosted Runner，恢复后必须从干净 Checkout 重新执行完整门禁。

## 5. GitHub Actions 结构

以下供应链约束同时适用于日常 CI 与 Release workflow：

- 工作流默认权限为 `contents: read`，只在明确需要的 Job 提升权限；
- 所有外部 Actions 固定完整 Commit SHA，并在注释中记录对应版本；
- 不使用可移动的 `@main`、`@master` 或仅主版本标签。

### 5.1 `.github/workflows/ci.yml`

触发范围：

- Pull Request 指向 `develop` 或 `master`；
- Push 到 `develop` 或 `master`。

职责：

1. Checkout 精确 Commit；
2. 校验 Release Runner 预检脚本与受控工作流契约；
3. 输出 Xcode 与 Swift 版本；
4. 校验 `Package.resolved` 未被解析过程改写；
5. 执行 XCTest；
6. 执行 Release 编译检查；
7. 保存失败时需要的测试结果和构建日志。

CI 专属权限约束：

- 工作流保持 `contents: read`；
- 不授予 Release、Issues、Pull Requests 或 Packages 写权限。

### 5.2 `.github/workflows/release-runner-validation.yml`

只允许 `workflow_dispatch`，使用 `self-hosted`、`macOS`、`ARM64`、`release` 四个标签的交集选择专用 Runner。该受控验证工作流负责：

1. 执行 Release Runner 服务、架构、固定 Xcode、磁盘、工作区和挂载卷预检；
2. 使用锁定依赖在 `arm64` 上运行全部 XCTest；
3. 生成 Release App，并确认可执行文件仅包含 `arm64`；
4. 失败时上传诊断日志与测试结果；
5. 无论成功或失败都清理宿主机上的未发布产物。

该工作流不切换 Xcode、不创建 DMG、不写入 Tag 或 GitHub Release，也不能替代正式 Dry Run。

### 5.3 `.github/workflows/release.yml`

只允许 `workflow_dispatch`。输入至少包括：

- `mode`: `dry-run` 或 `release`；
- `version`: 例如 `0.1.0`；
- `target_sha`: 完整 Commit SHA。

共同前置校验：

1. `target_sha` 必须存在；
2. `target_sha` 必须等于远端 `master` 当前 HEAD；
3. 工作区必须精确 Checkout 到 `target_sha`；
4. 工作区必须干净；
5. Xcode 必须为 `26.6 (17F113)`；
6. Xcode 项目版本必须与输入版本和预期 Build 一致；
7. 正式模式下，同名 Tag 和 Release 必须不存在。

共同构建步骤：

1. 使用锁定依赖执行全部 XCTest；
2. 生成仅含 `arm64` 的 Release App；
3. 对完整 App Bundle 执行 ad-hoc 签名；
4. 执行 `codesign --verify --deep --strict`；
5. 生成 dSYM；
6. 制作简洁 DMG；
7. 挂载并验证最终 DMG；
8. 生成并复核 SHA-256；
9. 上传构建日志、测试结果与 dSYM，保留 90 天。

权限分层：

- 测试、构建和校验 Job 使用 `contents: read`；
- 只有正式模式的 Tag/Release Job 使用 `contents: write`；
- 正式写入步骤必须依赖全部门禁成功，不允许使用 `continue-on-error` 绕过。

## 6. App 与 DMG 产物契约

### 6.1 App

最终 App 必须满足：

- 路径为 `DevEnv.app`；
- Bundle ID 为 `io.github.zh826256645.DevEnv`；
- `CFBundleShortVersionString` 为发布版本；
- `CFBundleVersion` 为对应 Build；
- 主可执行文件存在且具有执行权限；
- 主可执行文件只包含 `arm64`；
- 不包含测试 Bundle 或 XCTest Framework；
- App Icon 来自项目现有 `AppIcon.appiconset`；
- 完整 App Bundle 已做 ad-hoc 签名并通过严格校验。

ad-hoc 签名只提供 Bundle 内部完整性校验，不构成开发者身份信任，也不会让 App 通过 Gatekeeper 分发评估。发布说明不得把它描述成 Developer ID 签名或 Apple 公证。

### 6.2 DMG

DMG 采用不依赖 Finder 或 AppleScript 的简洁结构：

- `DevEnv.app`
- 指向 `/Applications` 的 `Applications` 符号链接

首版不加入自定义背景、Finder 窗口尺寸或图标坐标。目标是让 CI 稳定生成和验证结构一致的安装卷，而不是保证不同运行之间的 DMG 字节完全相同。

最终校验必须挂载发布文件本身，并验证：

- 卷能够只读挂载；
- App 和 `Applications` 链接存在；
- 链接目标准确；
- App 版本、Build、Bundle ID 和架构准确；
- App 可执行文件与资源完整；
- ad-hoc Bundle 签名有效；
- SHA-256 文件与 DMG 实际摘要一致；
- 校验完成后卷能够正常卸载。

## 7. 数据兼容边界

`v0.1.0` 保留现有开发构建中的 Project Record、Project Run Configuration 和 Project Trust：

- Project Record schema 1–4 的迁移测试必须通过；
- 不允许静默丢弃或覆盖不兼容的 Project Record；
- Machine Snapshot 是可重建缓存；旧 schema 无法读取时可以重新执行 Environment Scan；
- Machine Snapshot 重建不应被描述成 Project Record 数据丢失。

## 8. 发版步骤

### 8.1 准备

1. 在 `develop` 完成 CI、Release Runner、打包脚本、发布工作流和文档；
2. 确认 `v0.1.0` Milestone 中没有开放的 Release Blocker；
3. 确认版本为 `0.1.0 (1)`；
4. 准备中文 Release Notes，至少包含版本定位、系统要求、架构、安装限制、安装步骤、主要变更、Known Limitations 和校验方法；
5. 创建并合并 `develop → master` Release PR；
6. 记录目标 `master` 完整 SHA。

### 8.2 Dry Run

1. 启动专用 Apple Silicon Release Runner；
2. 手动触发 `release.yml`，选择 `dry-run`；
3. 输入 `0.1.0` 和目标 `master` SHA；
4. 等待全部测试、构建、签名、DMG 和校验步骤通过；
5. 确认 Actions Artifact 中存在 DMG、SHA-256、dSYM、测试结果和构建日志；
6. Dry Run 不创建 Tag 或 GitHub Release。

Dry Run 失败时，修复必须先进入 `develop`，再通过新的 `develop → master` PR 晋级；随后使用新的 `master` SHA 重新 Dry Run。

### 8.3 正式发布

1. 确认 Dry Run 已对当前 `master` SHA 成功；
2. 再次触发 `release.yml`，选择 `release`；
3. 工作流重新执行全部硬门禁，不复用未经重新验证的本地输出；
4. 门禁通过后创建 `v0.1.0` annotated Tag；
5. 创建 Draft GitHub Prerelease，上传 DMG 和 SHA-256；
6. 仓库所有者核对 Tag、目标 SHA、文件名、摘要和中文 Release Notes；
7. 在 GitHub UI 发布 Prerelease；
8. 停止专用 Runner，并清理未发布工作目录；
9. 关闭 Milestone 中已完成的发版任务。

当前规划不要求人工功能冒烟。实际发布的 arm64 App 必须由专用 Apple Silicon Runner 执行 XCTest，并通过最终 DMG 自动校验。

## 9. 发布失败与后续修订

### 9.1 Draft 被否决

正式工作流已创建 Tag 后，如果 Draft 因产物或内容问题被否决：

- 不移动或删除后重打同名 Tag；
- 记录否决原因；
- 修复后增加 Patch 版本并重新执行完整流程。

### 9.2 已发布版本出现严重问题

- 保留原 Release 和 Tag 的审计记录；
- 在 Release Notes 顶部标明已知严重问题；
- 必要时撤下 DMG，但保留版本说明；
- 修复从 `develop` 晋级到 `master`；
- 发布新的 Patch 版本，不替换旧二进制。

## 10. 不属于 v0.1.0 的工作

以下工作不阻塞 `v0.1.0`，应单独跟踪：

- Developer ID Application 签名；
- Hardened Runtime 正式分发配置；
- Apple Notary Service 公证；
- DMG Stapling 与 Gatekeeper 正向评估；
- 自动更新；
- 面向公开仓库或公众分发的许可证、隐私和支持政策。

在测试范围扩大到非仓库成员之前，应优先完成 Developer ID 签名、公证与 Stapling。
