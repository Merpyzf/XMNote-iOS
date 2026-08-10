# UICollectionView 可取消快照与 SwiftUI 协作：Compose 到 SwiftUI 迁移总结

## 适用场景

单书工作台同时具备以下特征：四个内容域、长富文本、独立滚动现场、搜索和持久化排序。单纯把所有派生计算放进 SwiftUI `body`，会让数据库观察、搜索输入和列表复用同时触发昂贵分组与富文本预热。最终实现采用三层协作：

1. `BookDetailViewModel` 持有数据库观察结果和业务写入。
2. `BookWorkspacePresentationStore` 把输入转换为可取消、带 revision 的展示快照。
3. `BookWorkspaceCollectionView` 用 diffable data source 应用最新快照并保留四域滚动现场。

## 1. Diffable Data Source 的身份设计

Diffable snapshot 依赖稳定、唯一的 section/item ID。身份来自数据库记录或明确的展示枚举，不能来自数组下标，也不能在每次刷新时重新生成 UUID。

```swift
enum WorkspaceItemID: Hashable {
    case header
    case chapter(Int64)
    case note(Int64)
    case related(Int64)
    case review(Int64)
}
```

这样做有三个直接收益：

- 搜索或排序只移动既有 item，不会被误判为全量删除重建。
- cell 复用时可以按业务 ID 找回展开状态。
- 对同一数据快照重复 apply 保持幂等。

Compose 中的对应概念是 `LazyColumn.items(key = { it.id })`。两端原则相同：业务身份稳定，渲染位置可变。

## 2. 用 revision 保证“最新输入优先”

搜索输入、数据库观察和排序设置可能快速连续变化。旧任务即使收到取消，也可能已经进入不可取消的同步计算，所以仅调用 `Task.cancel()` 不足以保证最终显示正确。

展示 Store 同时使用取消和 revision：

```swift
@MainActor
func submit(_ input: PresentationInput) {
    revision &+= 1
    let expectedRevision = revision
    buildTask?.cancel()

    buildTask = Task {
        let snapshot = await Task.detached(priority: .userInitiated) {
            buildSnapshot(input)
        }.value

        guard !Task.isCancelled, expectedRevision == revision else { return }
        currentSnapshot = snapshot
    }
}
```

取消负责节省工作，revision 负责正确性。只有两者同时满足，过期结果才不会覆盖更新的搜索词或数据库状态。

Compose 中可类比 `mapLatest`：新输入到来会取消旧转换；若转换包含不响应取消的同步代码，仍需额外版本号或输入一致性检查。

## 3. SwiftUI 与 UIKit 的 owner 边界

桥接层最容易出错的地方，是 SwiftUI 更新和 UIKit delegate 互相写回形成循环。这里采用单向数据流：

```text
Repository observation
        ↓
BookDetailViewModel
        ↓
PresentationStore snapshot
        ↓
UIViewRepresentable.updateUIView
        ↓
UICollectionViewDiffableDataSource.apply
        ↓ user action
SwiftUI callback / ViewModel command
```

- SwiftUI 是业务状态 owner。
- UIKit 是布局、复用、滚动位置和 diff 应用 owner。
- Coordinator 只转发用户事件，不复制一份长期业务状态。
- `updateUIView` 必须比较快照 revision，避免每次 SwiftUI 刷新都重复 apply。

## 4. 四个常驻列表与视口恢复

四域若共用一个 Collection，每次切换都需要重建布局、恢复 offset 并处理不同 section 结构。最终让四个 Collection 常驻，只切换可见性：

- 每个域独立保存 `contentOffset` 和吸顶锚点。
- 隐藏域不销毁，不因切换而丢失展开态或滚动现场。
- 数据仍只由一个 ViewModel/Store 提供，避免形成四套业务 owner。

这类似 Compose 为不同 pager page 保持独立 `LazyListState`，但 UIKit 侧需要明确控制 view 生命周期和 snapshot 应用时机。

## 5. 富文本预热与可取消展示快照

收起态使用 `CollapsedRichTextPreview`，完整态使用 `RichText`。展示 Store 在已知宽度时可预热预览布局，但必须遵循：

- 字体、颜色、行距、最大行数和 display scale 与真实渲染同源。
- 预热是缓存优化，不改变业务数据。
- 任务取消或 revision 过期后不发布其展示快照。
- 展开状态按内容 ID 保存在 Store，不能寄存在复用 cell。

## 6. 线程、取消与竞态检查清单

- Repository 观察结果回到 `@MainActor` 后再写 ViewModel。
- 纯派生计算可以移出主线程，但不能携带非 Sendable 的 UIKit view。
- 创建新任务前取消旧任务；页面消失时取消观察和派生任务。
- 发布结果前同时检查 `Task.isCancelled` 和 revision。
- UIKit snapshot 只在主线程应用。
- 连续退出重进时，旧页面任务不得写入新页面 owner。

## 7. 何时不该使用这套结构

只有少量静态行、没有独立滚动现场且派生计算很轻时，SwiftUI `List`/`ScrollView` 更直接。原生 Collection + 展示 Store 是为已证明存在的长列表、复用、快照竞态和多域现场问题服务，不应成为所有页面的默认基础设施。

## 代码证据

- `xmnote/Views/Book/BookDetailView.swift`
- `xmnote/Views/Book/Components/BookWorkspaceCollectionView.swift`
- `xmnote/Views/Book/Components/BookWorkspaceNoteItem.swift`
- `xmnote/ViewModels/Book/BookWorkspacePresentationStore.swift`
- `xmnote/UIComponents/Foundation/ExpandableRichText.swift`
- `xmnote/UIComponents/Foundation/CollapsedRichTextPreview.swift`

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
