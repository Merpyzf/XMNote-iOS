# Navigation/
> L2 | 父级: /CLAUDE.md

路由定义层。每个 Tab 对应一个路由枚举，配合 NavigationStack + NavigationPath 实现类型安全导航。

## 成员清单

- `BookRoute.swift`: 书籍模块路由枚举与目的地解析
- `ContentRoute.swift`: 书摘/书评/相关内容 Viewer 与编辑路由
- `NoteRoute.swift`: 笔记模块路由枚举与目的地解析
- `PersonalRoute.swift`: 个人模块路由枚举与目的地解析
- `ReadingRoute.swift`: 在读模块路由枚举与目的地解析（书籍详情/阅读计时/阅读日历）
- `ReadCalendarRoute.swift`: 阅读日历、日期详情与分享相关路由
- `AppNavigationCoordinator.swift`: 各 Tab NavigationPath、全屏任务、底栏抑制与跨模块跳转 owner

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
