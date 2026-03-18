# ViewModels/
> L2 | 父级: /CLAUDE.md

ViewModel 层目录，统一承载页面状态管理与业务编排逻辑。按 Feature 镜像 `xmnote/Views/<Feature>/` 组织，便于跨页面检索与迁移追踪。

## 目录约束

- `xmnote/ViewModels/<Feature>/`: 对应 `xmnote/Views/<Feature>/` 的 ViewModel 集合。
- `xmnote/ViewModels/**`: 仅允许放置 `*ViewModel.swift`（及同层必要的 ViewModel 辅助类型文件）。
- `xmnote/Views/**`: 禁止放置 `*ViewModel.swift`；页面壳层、页面私有组件、业务 Sheet 仍归 `Views`。

## 当前子目录

- `Book/`: 书籍模块 ViewModel
- `Content/`: 书摘/书评/相关内容查看与编辑 ViewModel
- `Note/`: 笔记模块 ViewModel
- `Personal/`: 个人模块 ViewModel（含 `Backup/`）
- `Reading/`: 在读模块 ViewModel（含 `ReadCalendar/`）
- `Debug/`: 调试页 ViewModel

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
