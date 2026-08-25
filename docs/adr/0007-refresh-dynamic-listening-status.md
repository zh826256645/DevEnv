# 定时刷新动态监听状态

应用启动和手动“重新扫描”继续执行完整 Environment Scan，并原子持久化整份 Machine Snapshot。另行提供可配置的 Dynamic Status Refresh：只重新观察 Local Service，并以真实可执行文件路径重新计算已知 Database Installation 的 Database Listening State；不重新发现安装、不读取版本、不调用其他 Provider，也不持久化结果。

定时刷新默认开启，前台 10 秒、后台 60 秒。用户可在侧边栏左下角的设置页关闭刷新，或将前台间隔调整为 5–300 秒、后台间隔调整为 30–3600 秒；后台间隔不得短于前台。设置保存后才生效并跨重启保留，应用从后台回到前台时立即刷新一次。

## Consequences

- 高频观察只执行既有的固定 `lsof` 只读命令，完整 Environment Scan 的成本和持久化语义保持不变。
- 数据库与本地服务页面显示最近一次成功 Dynamic Status Refresh 时间；总览的“最近扫描”仍表示完整 Environment Scan。
- Dynamic Status Refresh 失败时保留上一次成功结果并显示横幅，后续成功后自动清除。
- 新增的局域网暴露 Listener Binding 会进入既有通知入口并标记未读；相同结果不会因周期刷新反复标记。
- 新安装、卸载或版本变化不会由 Dynamic Status Refresh 发现，用户需要执行完整 Environment Scan。
