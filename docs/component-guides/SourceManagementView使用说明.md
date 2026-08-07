# SourceManagementView 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Personal/SourceManagementView.swift`。
- 角色：“我的 > 书籍来源”的范围切换、搜索、新增、重命名、排序和删除入口。
- 边界：默认来源与用户来源共享页面，但权限和可操作能力由业务快照决定。

## 快速接入

```swift
SourceManagementView()
```

页面必须位于已注入 `RepositoryContainer` 和 `XMToastCenter` 的应用环境中。

## 参数说明

`SourceManagementView` 没有外部业务参数。当前范围、搜索、排序态和写入门闩由 `SourceManagementViewModel` 持有，Repository 从环境容器注入。

## 示例

```swift
case .bookSource:
    SourceManagementView()
```

`XMScopeSelector` 在“我的来源”和“默认来源”间切换；搜索或筛选结果不允许进入手动排序，避免提交不可解释的局部顺序。

## 常见问题

### 默认来源可以删除或重命名吗？

页面按快照能力禁用不允许的操作，不用视觉约定代替数据层约束。

### 为什么搜索状态下不能排序？

搜索结果不是完整顺序集合，直接保存会丢失未显示项的位置。页面会在入口前阻断并解释。

### 删除来源如何处理关联书籍？

由 `SourceManagementRepository` 按 Android v45 的事务、外键和 `is_deleted` 条件处理，ViewModel 不拼接 SQL。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
