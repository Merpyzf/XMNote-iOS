# XMTagSelectionSheet 使用说明

`XMTagSelectionSheet` 是跨功能复用的标签关系编辑 Sheet，统一标签搜索、选择草稿、创建、可选的改名与删除，以及异步保存反馈。组件只接收纯展示值和动作闭包；Repository、持久化策略与业务刷新仍由调用方持有。

- 源码：`xmnote/UIComponents/Business/Tag/XMTagSelectionSheet.swift`
- 展示入口：`xmnote/Views/Debug/DesignSystemGalleryView.swift`

## 快速接入

调用方先把领域模型映射为 `XMTagSelectionItem`，再注入布局偏好和写入动作：

```swift
XMTagSelectionSheet(
    title: "编辑标签",
    items: items,
    initialSelectedIDs: selectedIDs,
    layout: XMTagSelectionLayoutConfiguration(
        initialMode: layoutMode,
        onChange: onLayoutModeChange
    ),
    onCreate: createTag,
    onSave: saveSelection
)
```

只有调用场景允许管理标签目录时，才传入 `XMTagSelectionManagementConfiguration`。

## 参数说明

- `items`：组件当前可展示的稳定标签值，只包含 `id` 与 `title`。
- `initialSelectedIDs`：打开 Sheet 时的选择基线；组件在内部维护本次编辑草稿。
- `allowsEmptySelection`：是否允许保存空集合。
- `isLoading`、`loadErrorMessage`：调用方读取状态的展示输入。
- `layout`：初始布局模式及模式变化回调，偏好持久化 owner 仍在调用方。
- `management`：可选的标签范围、改名、删除与目录变更动作。
- `onCreate`：创建标签并返回新展示项的异步动作。
- `onSave`：接收最终选择项；返回 `true` 时组件关闭，返回 `false` 时保留现场。
- `contextText`：可选上下文说明，不应承载业务逻辑。

## 示例

书摘、回顾、详情、每日阅读或书架批量编辑可各自持有 Repository，通过 ViewModel 或页面组合层完成以下适配：

1. 把领域标签映射成 `[XMTagSelectionItem]`。
2. 把真实创建、保存、改名和删除写入包装成最小异步闭包。
3. 在动作成功后由调用方更新领域状态；组件只维护当前 Sheet 的瞬时草稿和反馈。

组件已经覆盖 normal、focused、selected、disabled、loading、error、empty 与 editing 状态；动态字体时工具区会改为纵向布局，并读取 Reduce Motion 环境降低不必要动效。

## 常见问题

### 为什么不能直接把 Repository 或 ViewModel 传进组件？

这会让公共 UI 反向依赖业务与数据层，破坏复用边界，也使 Preview 和测试必须构造真实环境。根据 DS008，调用方必须完成领域值映射并注入最小动作。

### 单页面临时标签筛选也要用它吗？

不一定。仅用于本地筛选、没有标签关系编辑语义的页面应保留页面私有组合，不要为了统一外观引入完整管理能力。

### 谁负责加载和保存状态？

调用方负责真实读取状态与持久化；组件负责当前 Sheet 内的选择、搜索、创建/改名/删除任务和保存中的瞬时 UI 状态，并在消失时取消自己持有的任务。

### 如何预览组件？

使用设计系统 Debug 展厅中的 Hosted 场景。该场景提供完整 Sheet 与 Toast 环境，适合验证选择、创建、保存、深色模式和动态字体，不需要连接 Repository。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
