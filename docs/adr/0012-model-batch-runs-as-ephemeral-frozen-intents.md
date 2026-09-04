# 将批量运行建模为临时冻结意图

DevEnv 将用户明确触发的批量启动或停止建模为 Project Run Batch Intent，而不是持久化运行组或编排任务。意图在触发时按入口作用域解析并冻结：运行页使用当前项目筛选与搜索结果，状态栏使用全部项目；它只负责一次性提交多个彼此独立的单项动作，避免确认内容、后续筛选变化和实际操作目标发生漂移。

## Consequences

- 批量启动只纳入已启用、当前没有 Active Project Run Execution 且 Project Root 未明确不可用的配置；可用性仍为 `unknown` 的配置保持现有语义，仍可进入批量并由单项启动决定是否拒绝。
- 每个启动目标冻结当前有效的 Project Run Configuration（包括 App 内 command draft）、Project Root、完整命令和解析后的工作目录。无法解析工作目录的候选立即形成该配置自己的 Project Run Failure，其余目标继续。
- 冻结保证确认与执行使用同一启动请求，但不绕过执行时的安全复核；配置启用状态、Project Root、工作目录边界和活动运行冲突变化只拒绝对应目标，不以新命令或新目录替换已核对内容。
- 批量启动跨越未信任 Project Root 时，确认必须逐项展示完整命令与解析后的工作目录。Project Trust 仍按 Project Root 独立保存；某个 Root 保存失败只阻止该 Root 的目标，其余目标继续。
- 批量停止冻结触发时的 Project Run Execution 身份，不得误停之后为同一配置创建的替代 Execution；目标处于重启中时，同时取消尚未发起的后续 Execution。
- 目标之间没有顺序、就绪等待、依赖传播或原子性，也不进入批次级限流队列；DevEnv 立即逐项提交，单项拒绝、启动失败或停止失败不阻断其余目标。
- Project Run Batch Intent 提交后即结束，不提供批次级进度、完成态或历史；用户继续通过各 Project Run Session 和 Project Run Failure 观察结果。
- Project Run Session 是可由同一配置后续运行复用的交互式终端上下文；每次启动或重启创建具有独立身份的 Project Run Execution，以支持精确冻结批量停止目标。
