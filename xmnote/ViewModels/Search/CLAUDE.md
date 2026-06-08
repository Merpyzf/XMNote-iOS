# ViewModels/Search
> L2 | 父级: ViewModels/CLAUDE.md

全局搜索状态编排模块，负责把系统搜索框 query 转换为本地搜索请求、加载阶段、错误态、筛选状态与导航所需结果。

## 成员清单

- `GlobalSearchViewModel.swift`: 全局搜索页状态源，承接四类本地搜索、query 防抖、任务取消与结果筛选。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
