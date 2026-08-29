# 不启用 App Sandbox

DevEnv 需要读取 Shell 配置、扫描 PATH 并调用 Homebrew 等本机工具，这些核心能力与 App Sandbox 冲突，因此应用不启用沙盒并先仅供本机使用。所有修改环境的操作必须先展示具体命令并由用户确认，以约束非沙盒运行带来的风险。Project Run 按 [ADR-0010](0010-separate-trusted-project-runs-from-environment-scans.md) 建立 Project Root 级信任：首次执行展示完整命令和工作目录并确认，后续仍需用户显式点击运行，但可复用该本地信任记录。
