# DevEnv

DevEnv 帮助 macOS 开发者理解本机的开发工具状态，并将其与项目要求或期望配置区分开。

## Language

**Machine Environment**:
一台 Mac 在某个时刻与开发相关的工具、运行时和服务的实际状态。
_Avoid_: Environment, Development Environment

**Project Requirements**:
一个项目明确声明的运行时、工具和服务要求，而不是本机的实际状态。
_Avoid_: Project Environment

**Environment Profile**:
一套可移植的目标配置，描述期望存在的开发工具状态。
_Avoid_: Environment

**Environment Scan**:
对当前 Mac 的 Machine Environment 进行一次只读观察，形成可展示的状态结果。
_Avoid_: Environment Check, Health Check

**Machine Snapshot**:
一次 Environment Scan 产生的、描述主机基础信息与开发工具状态的结果。
_Avoid_: Environment, System Profile

**Runtime Installation**:
本机可被发现的某个语言运行时实例，包含其版本与来源位置。
_Avoid_: Runtime, Package

**Effective Runtime Installation**:
当前 `PATH` 对某类语言运行时优先解析到的 Runtime Installation。
_Avoid_: Current Runtime, Active Runtime

**Runtime Conflict**:
同类语言运行时存在多个不同的 Runtime Installation，且它们可能因 `PATH` 顺序产生不同解析结果的状态。
_Avoid_: Version Conflict, PATH Error

**Homebrew Availability**:
Homebrew 在当前 Mac 上是否可调用，以及可识别的安装位置。
_Avoid_: Homebrew Environment
