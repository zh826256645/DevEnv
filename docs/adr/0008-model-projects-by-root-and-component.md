# 按 Project Root 与 Component 建模项目要求

DevEnv 以最近 Git 根、项目主清单或用户明确选择的目录确定 Project Root，并以目录内的 Project Component 保存各自的 Project Requirements；嵌套 Git 根和用户明确选择的嵌套边界保持独立。一次性的 Project Search Root 不持久化，DevEnv 按规范路径持久化轻量 Project Record 与 Ignored Project，并按 [ADR-0010](0010-separate-trusted-project-runs-from-environment-scans.md) 保存 App 私有的 Project Run Configuration 与 Project Trust；扫描时重建要求和比较结果。因此 monorepo 不会重复吸收清单，而移动后的项目会作为新路径出现并由用户移除旧记录。
