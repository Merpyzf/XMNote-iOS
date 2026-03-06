# Views/
> L2 | 父级: /CLAUDE.md

SwiftUI 视图层，按功能模块分子目录组织页面壳层、页面私有子视图与业务 Sheet。ViewModel 统一迁移到 `xmnote/ViewModels`。

## 顶层成员

- `MainTabView.swift`: 四 Tab 根视图（在读/书籍/笔记/我的）

## 子目录

- `Book/`: 书籍管理视图
- `Note/`: 笔记管理视图
- `Personal/`: 个人设置视图（含 Backup/ 子目录）
- `Reading/`: 在读追踪视图（含 ReadCalendar/ 子功能）
- `Statistics/`: 统计占位视图
- `Debug/`: 调试测试视图（#if DEBUG 编译隔离，含 Prototypes/ 原型子目录）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
