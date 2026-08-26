## Agent skills

### Issue tracker

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations. See `docs/agents/issue-tracker.md`.

- 拆分父子任务时，必须使用 GitHub 原生 Sub-issues 建立关系，并核对父 Issue 显示正确的子任务进度；正文中的 `Parent` 引用不能替代原生关系。
- 子任务存在先后依赖时，必须使用 GitHub 原生 issue dependencies 建立 `blocked by` / `blocking` 关系，并核对被阻塞 Issue 显示 `Blocked`；正文中的 `Blocked by` 说明不能替代原生关系。

### Pull requests

每次推送时，都必须提供与本次变更对应的 PR 标题和描述；用户要求创建 PR 时，使用该标题和描述通过 `gh` CLI 创建。

### Triage labels

Uses the default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.

### UI assets

- UI 中已有的 Logo 必须统一复用项目现有资源；Git、Runtime 等已有 Logo 禁止使用 SF Symbols、文字或自绘图形替代。仅在确认项目中不存在对应资源时才可新增。
- 同一 Logo 在不同功能页面必须复用统一的品牌色、圆角底板和内边距样式；允许整体尺寸随页面层级等比例调整，不得单独覆写为另一套视觉。
