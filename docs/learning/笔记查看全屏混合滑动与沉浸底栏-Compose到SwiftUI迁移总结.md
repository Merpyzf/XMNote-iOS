# 笔记查看全屏混合滑动与沉浸底栏（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- `TabView(.page)` 不是所有横向分页场景的通解；当页面同时需要“页内纵向滚动 + 底部沉浸 overlay + 精确 safe area 控制”时，自建 paging 更稳定。
- `ScrollView(.horizontal) + LazyHStack + .scrollTargetBehavior(.paging) + .scrollPosition` 可以做出接近 `ViewPager2` / `HorizontalPager` 的控制力。
- 横向分页的性能关键不只是懒渲染，还包括“窗口化可见页 + 邻页预取详情”。
- 底部沉浸渐变不要只把 ornament 摆上去，还要同步处理：
  - 手势导航条区域覆盖
  - 正文尾部可读留白
  - 滚动条避让 inset
- 这类“查看器壳层”最适合抽 `Metrics + Overlay + Icon` 三段式复用，而不是让每个页面各自手写 gradient 和 safe area 逻辑。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose/旧 Android 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 书摘横向翻页 | `ViewPager2` / `HorizontalPager` | `ScrollView(.horizontal)` + `.paging` | 不迷信单一容器，优先稳定性 |
| 混合内容查看 | 多 Activity 分叉 | 单一 `ContentViewerView` | 收敛路由，优先业务连续性 |
| 相邻页加载 | 接近尾部时预加载下一页 | `prefetchDetails(around:radius:)` | “切页前准备好”比“切页后补救”更关键 |
| 底部悬浮工具栏 | XML/Compose 单页局部实现 | `ImmersiveBottomChromeOverlay` | 视觉与 safe area 统一抽象 |
| 页内可读尾部 | 列表底部额外 Spacer | `metrics.readableInset` + `contentMargins` | 不只补内容，还要补滚动指标 |

## 3. 架构拆分：为什么要把 viewer 拆成壳层 / 内容层 / 正文 body

### 3.1 壳层负责路由、导航栏和底部动作
- `NoteViewerView` / `ContentViewerView`
- 职责：
  - 初始化 ViewModel
  - 处理删除确认、sheet、toolbar
  - 挂底部 ornament

### 3.2 内容层负责横向分页
- `NoteViewerContentView` / `ContentViewerContentView`
- 职责：
  - 管理 horizontal pager position
  - 处理滑动中态与最终选中态提交
  - 挂载窗口化页面

### 3.3 正文 body 负责单页展示
- `ContentViewerDetailBodies`
- 职责：
  - 统一书摘、书评、相关内容正文结构
  - 避免两个 viewer 壳层复制一份正文布局

这个拆法的好处是：
- 以后再接入新内容类型，只需要扩充 detail model 与 body 渲染。
- 底部 chrome 和分页机制不需要跟着正文布局一起改。

## 4. 自建 paging 的核心实现

### 4.1 为什么不用 `TabView`
- 用户已确认该场景下 `TabView` 会出现内容区域莫名上移。
- 当页面还有底部 overlay、安全区沉浸与页内滚动时，问题更难压住。

### 4.2 当前做法
```swift
ScrollView(.horizontal, showsIndicators: false) {
    LazyHStack(spacing: Spacing.none) {
        ForEach(props.pages) { page in
            PageView(page: page)
                .frame(width: pageWidth, height: pageHeight)
                .id(page.item.id)
        }
    }
    .scrollTargetLayout()
}
.scrollTargetBehavior(.paging)
.scrollPosition(id: $horizontalPagerPosition, anchor: .topLeading)
```

关键点：
- 用 `LazyHStack` 控制真实挂载页数。
- 用 `scrollPosition` 同步程序化选中。
- 用 `onScrollPhaseChange` 等手势结束后再提交最终选中页，避免滑动过程疯狂回写状态。

## 5. 懒加载不是只有 `LazyHStack`

很多 Android 开发者会把“懒加载”理解成只要用了懒容器就结束了，但这次 viewer 的懒加载其实有两层：

1. 页面挂载懒加载
- 只挂载当前页附近的窗口。
- 对应 `visibleNoteItems(radius:)` / `visibleItems(radius:)`。

2. 详情数据懒加载
- 当前页按需加载详情。
- 切到当前页后再刷新详情，保证从编辑页返回的数据最新。
- 额外预取左右邻页，降低切页白屏。

这比“全量页 + 每页都自己 task 拉数据”更可控。

## 6. 沉浸底栏的实现拆法

### 6.1 度量先行
```swift
let metrics = ImmersiveBottomChromeMetrics.make(
    measuredOrnamentHeight: bottomOrnamentHeight,
    safeAreaBottomInset: proxy.safeAreaInsets.bottom
)
```

### 6.2 overlay 负责渐变和安全区
```swift
ImmersiveBottomChromeOverlay(metrics: metrics) {
    bottomOrnament
}
```

### 6.3 正文滚动区补尾部可读留白
```swift
ScrollView {
    content
    Color.clear.frame(height: max(Spacing.base, metrics.readableInset))
}
.contentMargins(.bottom, metrics.scrollIndicatorInset, for: .scrollIndicators)
.ignoresSafeArea(.container, edges: .bottom)
```

迁移原则：
- 视觉层不是只管“好不好看”，还要反推正文和滚动指标的布局补偿。

## 7. 可运行 SwiftUI 示例
```swift
import SwiftUI

struct PagerItem: Identifiable, Hashable {
    let id: Int
    let title: String
}

struct ImmersivePagerDemoView: View {
    let items = (0..<10).map { PagerItem(id: $0, title: "Page \($0)") }

    @State private var selectedID: Int? = 0
    @State private var ornamentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let metrics = ImmersiveBottomChromeMetrics.make(
                measuredOrnamentHeight: ornamentHeight,
                safeAreaBottomInset: proxy.safeAreaInsets.bottom
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        ScrollView {
                            Text(item.title)
                                .frame(maxWidth: .infinity, minHeight: 400)
                            Color.clear.frame(height: metrics.readableInset)
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $selectedID)
            .overlay(alignment: .bottom) {
                ImmersiveBottomChromeOverlay(metrics: metrics) {
                    HStack(spacing: 12) {
                        ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                        ImmersiveBottomChromeIcon(systemName: "trash", foregroundStyle: .red)
                    }
                    .padding(.horizontal, 16)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ImmersiveBottomChromeHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    }
                }
            }
            .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { ornamentHeight = $0 }
        }
    }
}
```

## 8. Compose 对照示例
```kotlin
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun MixedViewerDemo(items: List<String>) {
    val pagerState = rememberPagerState(pageCount = { items.size })

    Box(Modifier.fillMaxSize()) {
        HorizontalPager(state = pagerState) { page ->
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(bottom = 120.dp)
            ) {
                item {
                    Text(
                        text = items[page],
                        modifier = Modifier.fillMaxWidth().padding(16.dp)
                    )
                }
            }
        }

        Row(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 12.dp)
                .clip(RoundedCornerShape(999.dp))
                .background(Color.White.copy(alpha = 0.88f))
                .padding(horizontal = 16.dp, vertical = 10.dp)
        ) {
            Icon(Icons.Default.Edit, contentDescription = null)
            Spacer(Modifier.width(16.dp))
            Icon(Icons.Default.Delete, contentDescription = null)
        }
    }
}
```

## 9. 迁移结论
- Android 迁到 iOS 时，不要把“书摘查看 = ViewPager/TabView”当成固定答案。
- 真正应该对齐的是业务意图：
  - 能连续浏览
  - 能快速切页
  - 能直接操作当前内容
  - 删除后状态稳定
- 当 iOS 原生容器在该场景有已知缺陷时，优先收敛为可控的自建 paging 架构，再通过可复用沉浸底栏补齐体验。
