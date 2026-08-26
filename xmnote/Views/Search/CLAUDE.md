# Search/
> L2 | 父级: Views/CLAUDE.md

全局搜索视图模块，承载搜索 Tab 的页面壳层、本地搜索结果分区、类别筛选与业务状态映射；加载、无搜索结果与失败视觉统一复用 `StatePresentation` 组件族，交互保留 iOS 原生 search Tab 语义。

## 成员清单

- `GlobalSearchView.swift`: 全局搜索 Tab 根视图，承接搜索 query 绑定、顶部标题、结果列表与搜索结果导航回调。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
