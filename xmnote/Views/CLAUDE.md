# Views/
> L2 | 父级: /CLAUDE.md

SwiftUI 视图层，按功能模块分子目录组织页面壳层、页面私有子视图与业务 Sheet。ViewModel 统一迁移到 `xmnote/ViewModels`。

页面、Sheet、列表背景和局部容器的通用空态、无搜索结果、失败态与 Inline Banner 统一复用 `xmnote/UIComponents/Foundation/StatePresentation/`；页面私有 StateHost 只负责业务阶段映射和容器布局。

## 顶层成员

- `MainTabView.swift`: 五 Tab 根视图（在读/书籍/笔记/我的/搜索）

## 子目录

- `Book/`: 书籍管理视图
- `Content/`: 书摘/书评/相关内容查看与编辑视图
- `Note/`: 笔记管理视图
- `Personal/`: 个人设置视图（含 Backup/ 子目录）
- `Reading/`: 在读追踪视图（含 ReadCalendar/ 子功能）
- `Search/`: 全局搜索视图
- `Statistics/`: 统计模块兼容目录；当前空状态由 Reading 容器复用通用状态组件承接
- `Debug/`: 调试测试视图（#if DEBUG 编译隔离，含 Prototypes/ 原型子目录）

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
