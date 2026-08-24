# 通用状态展示收敛 - Compose 到 SwiftUI 迁移总结

## 1. 本次 iOS 知识点

- Apple 的 `ContentUnavailableView` 适合作为页面级内容不可用状态的排版基础，但项目仍需要统一角色、图标、动作和状态映射入口。
- “展示状态”不等于“业务状态机”：Repository/ViewModel 决定数据是否返回、是否为空和是否失败，UI 组件只消费已判定的语义。
- 空数据与无搜索结果必须分开。前者描述数据源，后者描述 query 或筛选条件下的派生结果。
- 已有内容的刷新失败不能覆盖成阻断页；保留可信内容并显示 Inline Banner，更能维持阅读上下文。
- Dynamic Type 下，横向图文结构应在辅助功能字号切换为纵向布局；动作仍保持独立的 44pt 热区和无障碍元素。
- Reduce Motion 不是取消状态反馈，而是把位移、缩放等运动降级为无动画或轻量 opacity 切换。

## 2. Android Compose 对照思路

| Compose 常见实现 | SwiftUI 对应实现 | 迁移判断 |
| --- | --- | --- |
| `Box` 中手写 `Icon + Text + Button` 空态 | `XMContentStateView` / `XMCompactStateView` | 页面不要重复组合视觉 |
| `CircularProgressIndicator` 立即显示 | `LoadingGate + LoadingStateView` | 读取类需要延迟显示和最短驻留 |
| `LazyColumn` 空列表直接显示 Empty | 先等待加载完成，再映射 `.empty` | 空态必须建立在真实数据事实之上 |
| 搜索结果为空复用 Empty | `.noResults` | 搜索派生为空不代表数据源为空 |
| Snackbar 覆盖刷新错误 | `XMInlineStatusBanner` 或 `XMToast` | 需要固定在内容中就用 Banner，短驻留消息才用 Toast |
| Composable 自己读取 ViewModel 并决定错误 | 页面 owner 映射角色，通用组件只接收值 | 组件不绑定业务状态源 |

## 3. 可运行对照示例

### 3.1 Android Compose

```kotlin
@Composable
fun SearchState(
    query: String,
    isLoading: Boolean,
    items: List<Book>,
    error: String?,
    onRetry: () -> Unit
) {
    when {
        isLoading -> CircularProgressIndicator()
        error != null -> Column {
            Icon(Icons.Default.Warning, contentDescription = null)
            Text("加载失败")
            Text(error)
            Button(onClick = onRetry) { Text("重试") }
        }
        items.isEmpty() -> Text(if (query.isBlank()) "暂无书籍" else "没有搜索结果")
        else -> LazyColumn {
            items(items) { BookRow(it) }
        }
    }
}
```

这段代码能工作，但 Loading、失败、空数据与搜索无结果的视觉会随页面复制，后续很难统一调整。

### 3.2 SwiftUI

```swift
@ViewBuilder
private var content: some View {
    switch phase {
    case .loading:
        LoadingStateView("正在加载…")

    case .loaded(let books) where books.isEmpty && !query.isEmpty:
        XMContentStateView(
            role: .noResults,
            title: "没有找到结果",
            message: "尝试更换关键词。"
        )

    case .loaded(let books) where books.isEmpty:
        XMContentStateView(
            role: .empty,
            title: "暂无书籍",
            message: "添加书籍后会显示在这里。"
        )

    case .failure(let message):
        XMContentStateView(
            role: .failure,
            title: "暂时无法加载",
            message: message,
            action: XMStateAction("重试") {
                Task { await reload() }
            }
        )

    case .loaded(let books):
        BookList(books: books)
    }
}
```

页面仍然拥有状态映射，因此不会把业务状态机塞进基础组件；公共组件只保证同一语义具有一致视觉和交互。

## 4. 容器适配的边界

SwiftUI 页面、UIKit 列表背景和 UICollectionView cell 对布局的要求不同。正确抽象不是消灭所有适配器，而是让适配器只保留必要职责：

- UIKit 生命周期与 hosting controller 管理。
- cell/background 的尺寸和复用。
- 业务阶段到通用角色的映射。

图标、字体、间距、颜色和动作样式必须继续交给 `XMContentStateView`、`XMCompactStateView` 或 `XMInlineStatusBanner`。这对应 Compose 中保留 `LazyListScope`/`Scaffold` 适配，但把空态视觉下沉到 design system Composable。

## 5. 迁移结论

- 先验证状态事实，再选择展示角色；不要根据数组暂时为空就推断真实空数据。
- 统一组件应该收敛相同语义，不应该吞掉业务状态 owner 或领域工作流。
- 页面级状态优先使用系统平台表达，卡片和局部容器再使用项目设计令牌补足。
- 失败反馈的第一判断不是“用什么红色”，而是“现有内容是否仍可信”。可信就保留内容，不可信才进入阻断态。
- 自动闸门应检查直接系统入口、旧组件回流和新增状态型 View；例外必须精确、可解释、可审查。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
