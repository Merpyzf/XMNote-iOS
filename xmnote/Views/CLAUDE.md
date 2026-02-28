# Views/
> L2 | 父级: /CLAUDE.md

SwiftUI 视图与 ViewModel 共置层，按功能模块分子目录。每个功能目录同时包含 View 和对应的 ViewModel。

## 顶层成员

- `MainTabView.swift`: 四 Tab 根视图（在读/书籍/笔记/我的）

## 子目录

- `Book/`: 书籍管理（8 个文件：6 View + 2 ViewModel）
- `Note/`: 笔记管理（7 个文件：5 View + 2 ViewModel）
- `Personal/`: 个人设置（2 个文件 + Backup/ 子目录含 6 个文件）
- `Reading/`: 在读追踪（6 个文件 + ReadCalendar/ 子目录含 3 个文件）
- `Statistics/`: 统计视图（占位）
- `Debug/`: 调试测试视图（#if DEBUG 编译隔离，5 个文件）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
