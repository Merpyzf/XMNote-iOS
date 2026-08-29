# NoteDetailView 使用说明

## 组件定位

- 源码路径：`xmnote/Views/Note/NoteDetailView.swift`。
- 角色：承载单条笔记的只读详情、编辑入口、内容失效和读取/保存反馈。
- 边界：页面通过 `NoteDetailViewModel` 使用 Repository；富文本编辑器和状态组件只消费展示状态，不直接读取数据库。

## 快速接入

```swift
NoteDetailView(noteId: noteId)
```

`noteId` 必须是稳定的笔记主键。编辑动作由页面通过 `AppNavigationCoordinator` 打开既有编辑器，不在详情页内创建第二套路由容器。

## 参数说明

| 参数 | 类型 | 必填 | 职责 |
| --- | --- | --- | --- |
| `noteId` | `Int64` | 是 | 目标笔记的稳定主键，也是 `NoteDetailViewModel` 读取详情的查询条件 |

页面还需要上层环境提供 `RepositoryContainer` 和 `AppNavigationCoordinator`；生产接入应复用 App 根部既有注入链路。

## 示例

```swift
case .noteDetail(let noteId):
    NoteDetailView(noteId: noteId)
```

示例 route 名称只用于说明职责，实际接入以调用方已有路由类型为准。

## 加载与内容状态

`NoteDetailViewModel.loadState` 是页面事实来源，页面按下列阶段渲染：

| 阶段 | 页面表现 |
| --- | --- |
| `idle / loading` | 内容保持空白；超过延迟阈值后由 `LoadingGate` 显示读取反馈 |
| `content` | 渲染书摘、想法和元信息，同时开放右上角“编辑”入口 |
| `missing` | 使用中性的页面级不可用状态“笔记不存在或已删除”，不提供无效重试 |
| `failure` | 使用页面级失败状态“暂时无法加载笔记”，提供纯文字“重试” |

- 数据成功读取前不得先渲染空编辑器，避免把“尚未加载”误报成“内容为空”。
- “编辑”只在 `content` 阶段出现；失效和失败阶段不能进入编辑流程。
- 保存失败时保留已经读取的详情，并通过 `XMInlineStatusBanner` 告知结果；不得用整页失败替换可信内容。
- 状态文案不透出数据库、服务器或网络实现细节。

## 常见问题

### 1. 为什么“笔记不存在或已删除”没有重试？

这是内容失效事实，不是可恢复的瞬时读取错误。无效重试会制造错误预期；只有初次读取失败才提供“重试”。

### 2. 这个页面是否可抽到 `UIComponents`？

不建议。它绑定笔记领域模型、富文本内容、编辑路由和加载生命周期，属于核心业务页面。可复用的状态与反馈已经由公共组件承担。

### 3. 是否允许页面直接访问 Repository？

不允许。数据读取和保存经 `NoteDetailViewModel` 编排，页面只消费可观察状态并触发用户动作。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
