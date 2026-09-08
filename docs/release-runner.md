# Apple Silicon Release Runner 操作手册

本文是 DevEnv 专用 Apple Silicon Self-hosted Runner 的安装、启停、验证、更新、清理和故障恢复手册。该 Runner 只服务于受控 Dry Run 与正式发版窗口，不作为长期在线的通用开发执行器。

自 v0.1.1 起，所有者可授权使用[本地发布通道](releasing.md#本地发布通道自-v011-起)，该通道不需要安装或注册 Runner。本文仅适用于选择 GitHub Actions 发布时。

发版契约与分支、Tag、DMG 规则见 [发版流程](releasing.md)。GitHub Runner 的下载命令、短期注册 Token 和当前版本号必须始终从仓库 **Settings → Actions → Runners → New self-hosted runner** 页面取得；不要把 Token、`.credentials` 或 Runner 诊断包提交到仓库。

## 1. 固定配置

| 项目 | 固定值 |
| --- | --- |
| 宿主机 | Apple Silicon Mac |
| CPU 架构 | `arm64` |
| Xcode | `26.6` |
| Xcode Build | `17F113` |
| Runner 名称 | `devenv-release-arm64` |
| Runner 标签 | `self-hosted`、`macOS`、`ARM64`、`release` |
| 工作目录 | Runner 安装目录内的 `_work` |
| 最低可用磁盘 | 50 GiB |
| 常态 | 服务停止，GitHub 页面显示 `Offline` |

不要使用 `--no-default-labels`。`self-hosted`、`macOS`、`ARM64` 由 GitHub Runner 根据宿主机添加，注册时额外添加 `release`；注册后必须在 GitHub 页面核对四个标签全部存在。

仓库中的 `.github/workflows/release-runner-validation.yml` 只允许手动触发，并用四个标签的交集精确选择该 Runner。工作流不会执行 `xcode-select` 或自动接受其他 Xcode 版本；`scripts/release-runner/preflight.sh` 发现工具链不匹配时会立即失败。

## 2. 首次安装与注册

1. 为 Runner 创建独立的非管理员 macOS 用户，并确保该用户只用于 DevEnv 发版任务。
2. 使用该用户登录，在用户目录创建专用安装目录：

   ```bash
   mkdir -p ~/actions-runner-devenv-release
   cd ~/actions-runner-devenv-release
   ```

3. 在仓库 **Settings → Actions → Runners → New self-hosted runner** 选择 `macOS` 和 `ARM64`，逐条执行页面给出的下载、SHA-256 校验和解压命令。不要复用历史下载地址或注册 Token。
4. 使用页面生成的短期 Token 注册，并保持默认标签：

   ```bash
   ./config.sh \
     --url https://github.com/zh826256645/DevEnv \
     --token '<短期注册 Token>' \
     --name devenv-release-arm64 \
     --labels release \
     --work _work \
     --unattended
   ```

5. 安装服务，但不要让它长期在线：

   ```bash
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status
   ```

6. 在 GitHub Runner 页面确认名称、`Idle` 状态和四个标签正确，然后停止服务并确认页面变为 `Offline`：

   ```bash
   ./svc.sh stop
   ./svc.sh status
   ```

Runner 安装、服务管理和标签行为以 GitHub 官方文档为准：

- [Adding self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
- [Configuring the self-hosted runner application as a service](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/configure-the-application)
- [Using self-hosted runners in a workflow](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow)

## 3. 发版窗口前启动与检查

以下命令假设 Runner 安装在 `~/actions-runner-devenv-release`。

1. 确认仓库中没有另一个 Release Runner 验证、Dry Run 或正式发布 Job 正在运行或等待。
2. 检查宿主机上没有需要保留的未发布产物，并启动服务：

   ```bash
   cd ~/actions-runner-devenv-release
   ./svc.sh start
   ./svc.sh status
   ```

3. 在 GitHub Runner 页面确认：
   - Runner 名称为 `devenv-release-arm64`；
   - 状态为 `Idle`；
   - 标签同时包含 `self-hosted`、`macOS`、`ARM64`、`release`；
   - 没有其他仓库或通用工作流能够用更宽泛的标签把任务派发到该主机。
4. 在宿主机执行基础核对：

   ```bash
   uname -m
   xcodebuild -version
   df -h ~/actions-runner-devenv-release
   hdiutil info
   ```

   预期架构为 `arm64`，Xcode 输出必须精确包含 `Xcode 26.6` 与 `Build version 17F113`。不要通过 `xcode-select` 临时切换到其他版本以绕过检查。
5. 手动触发受控验证工作流：

   ```bash
   gh workflow run release-runner-validation.yml --ref develop
   gh run list --workflow release-runner-validation.yml --limit 1
   ```

   也可在 GitHub Actions 页面选择 **Release Runner Validation → Run workflow**。工作流会再次检查服务状态、架构、Xcode、Git 工作区、至少 50 GiB 可用磁盘和残留挂载卷，然后在 `arm64` 上执行全部 XCTest 与 Release 构建，并校验 Release 可执行文件只有 `arm64` 架构。
6. 验证通过后，Runner 才能用于同一发版窗口内的 Dry Run 或正式发布。验证失败时不得改派到 GitHub Hosted Runner 或普通开发机。

## 4. 发版后停止与清理

`.github/workflows/release-runner-validation.yml` 的最后一步只在可信 Checkout 成功后调用 `scripts/release-runner/cleanup.sh`。脚本仅卸载镜像路径位于本次 `$RUNNER_TEMP` 且文件名符合 DevEnv 发版契约的卷，删除该临时目录下的 DerivedData、依赖缓存、测试结果、日志和未发布产物，并重置 Checkout；它不会仅凭卷名卸载其他磁盘镜像。

工作流结束后仍必须人工完成以下步骤：

1. 确认没有运行中或排队等待该 Runner 的 Job。
2. 如工作流被强制取消、宿主机断电或清理步骤未执行，先确认最近一次 Checkout 来自已核验的仓库提交且没有需要保留的改动，再手工运行：

   ```bash
   cd ~/actions-runner-devenv-release/_work/DevEnv/DevEnv
   scripts/release-runner/cleanup.sh \
     --workspace "$PWD" \
     --temp-root ~/actions-runner-devenv-release/_work/_temp
   ```

3. 再次检查并卸载任何确认属于本次发版的残留卷：

   ```bash
   hdiutil info
   hdiutil detach '/Volumes/DevEnv'
   ```

   仅在对应卷确实存在时执行 `detach`，不要卸载其他应用正在使用的卷。
4. 停止 Runner 服务：

   ```bash
   cd ~/actions-runner-devenv-release
   ./svc.sh stop
   ./svc.sh status
   ```

5. 在 GitHub 页面确认 Runner 为 `Offline`。GitHub Actions 中已上传的受控日志和测试结果按工作流保留策略保存，宿主机不长期保留副本。

## 5. Runner 更新

GitHub 要求 Self-hosted Runner 保持受支持版本。只在独立维护窗口更新，不要在 Dry Run 或正式发布 Job 中自动更新或替换 Runner。

1. 确认没有运行中或排队中的发版 Job，停止服务并记录当前 Runner 名称与标签：

   ```bash
   cd ~/actions-runner-devenv-release
   ./svc.sh stop
   ./svc.sh status
   ```

2. 按 GitHub Runner 页面或官方更新提示取得当前受支持的 `osx-arm64` 包与 SHA-256，不使用第三方镜像。
3. 按 GitHub 官方更新流程更新现有 Runner 应用；如果官方流程要求重新注册，先在 GitHub 页面生成新的短期移除/注册 Token，绝不复用或保存旧 Token。
4. 更新后启动服务，核对名称、四个标签、`arm64`、`Xcode 26.6 (17F113)` 和 `_work` 路径。
5. 触发完整的 `Release Runner Validation`。全部通过后停止服务；只有下一次发版窗口才重新启动。

不要在更新 Runner 应用时顺带升级或切换 Xcode。Xcode 变更必须先修改发版规范和预检契约，再单独评审。

## 6. 故障恢复

### Runner 不上线或不接单

1. `./svc.sh status` 检查服务；查看 GitHub Runner 页面是否 `Offline`、`Active` 或标签缺失。
2. 查看安装目录 `_diag/Runner_*.log` 和 macOS 服务日志，保留与失败时间对应的诊断文件。
3. 检查网络、磁盘、Runner 用户权限和 GitHub 注册状态。
4. 不要删除 `_work` 以外的 Runner 配置文件，也不要把 Job 改派到普通开发机。

### 工具链、磁盘、工作区或挂载卷预检失败

1. 保留预检输出和 GitHub Actions 诊断 Artifact。
2. Xcode 不匹配时停止发版；不得自动切换或放宽版本检查。
3. 磁盘不足时只删除已确认无需保留的 `_work`、`_temp` 和未发布产物。
4. 工作区不干净时先确认没有需要保留的改动，再运行清理脚本。
5. 用 `hdiutil info` 确认残留卷与镜像路径，只卸载属于 DevEnv 发版的卷。

### Job 中断或主机异常

1. 取消尚未完成的正式工作流并保存诊断日志。
2. 确认没有正在写入的 Tag 或 Draft Release；如果已经写入，按发版流程的回滚规则处理，不能只重跑后半段。
3. 清理工作区、临时目录和挂载卷，停止再启动 Runner。
4. 从干净 Checkout 对目标 SHA 重新执行完整验证或 Dry Run，不使用失败 Job 的 `Re-run failed jobs` 跳过前置门禁。

更多诊断入口见 [Monitoring and troubleshooting self-hosted runners](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/monitor-and-troubleshoot)。
