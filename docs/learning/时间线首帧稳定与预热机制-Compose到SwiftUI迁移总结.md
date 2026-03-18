# 时间线首帧稳定与预热机制（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 首帧体验问题的根因往往不是“请求慢”，而是“页面结构在数据返回前不断变化”。
- SwiftUI 中如果页面需要首开稳定，应该先区分两类状态：
  - `bootstrapping`：首屏快照尚未完成，只允许展示稳定壳层。
  - `refreshing`：已有内容后的刷新，旧内容必须继续留在屏幕上。
- 容器层可以负责 warmup，但 warmup 只能是优化项，不能承担正确性职责。
- 对首开页面来说，原子提交首屏快照比多次局部刷新更重要；用户更在意“看到几次结构变化”，而不是内部任务拆了几步。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 首开稳定 | `UiState.Loading/Content`，或页面先空后填 | 静态壳层 + `bootstrapPhase` | 先稳定结构，再考虑加载速度 |
| 容器预热 | 在 `LaunchedEffect` 或 pager 预创建阶段请求 | `ReadingContainerView` 持有 VM 并调用 `SubtabBootstrapCoordinator` | warmup 放在容器，页面只关心展示 |
| 刷新反馈 | `isRefreshing` + 保留旧列表 | `isRefreshing` + 旧内容在位 + 轻提示 | 首开与刷新不能共用一个 loading 语义 |
| 首屏数据提交 | 多个 State 分步写回 | `loadInitialData()` 并发抓取后一次性提交快照 | 减少用户可见的结构变更次数 |
| 子页保活 | `HorizontalPager` / `ViewPager2` 保活 | `KeepAliveSwitcherHost` 保活 + 业务预热分离 | 保活不等于预热，职责要拆开 |

## 3. 这次方案的第一性原理

### 3.1 为什么我不把“预热”当作最终答案
如果页面只有在预热命中时才看起来正常，那说明问题并没有被解决，只是被赌概率遮住了。

正确做法应该是：
- 即使 warmup 失败，页面也依然稳定。
- warmup 命中时，只是让用户更快看到正式内容。

所以本次真正解决问题的核心不是“加了预热”，而是：
- 增加静态壳层
- 增加首屏快照
- 增加 bootstrap / refresh 状态分离

### 3.2 为什么静态壳层比骨架更适合这里
这个场景的问题不是“用户不知道正在加载”，而是“页面在加载过程中像散架了一样”。

因此不需要：
- 大面积 shimmer
- 全屏 spinner
- 强提示 loading 文案

更合理的做法是：
- 直接给用户一个接近真实结构的静态壳层
- 让页面从第 1 帧开始就稳定
- 数据好了以后再一次性 reveal 正式内容

## 4. 架构拆分到底做了什么

### 4.1 `ReadingContainerView` 负责什么
- 创建并持有 `TimelineViewModel`
- 在容器 `.task` 中做一次低优先级 warmup
- 在用户切到 `.timeline` 时补一次高优先级 warmup 请求
- 把时间线页当作内容页注入，而不是让页面自己造状态

### 4.2 `SubtabBootstrapCoordinator` 负责什么
- 对二级页 warmup 去重
- 管理 `idle / warming / ready`
- 保证同一个 subtab 的首开任务只执行一次

### 4.3 `ReadingTimelineView` 负责什么
- 只根据 `viewModel` 是否就绪决定：
  - 走 `ReadingTimelineBootstrapShellView`
  - 还是走正式内容树
- 不负责决定 warmup 何时触发
- 不负责自己创建 `TimelineViewModel`

### 4.4 `TimelineViewModel` 负责什么
- 维护 `bootstrapPhase`
- 维护 `isRefreshing`
- 构建首屏快照
- 在 ready 后继续做相邻月份 marker 预加载

## 5. 为什么首开状态不能和刷新状态混在一起
很多页面都会写一个统一的 `isLoading`，然后：
- 首次进入是 `true`
- 切换筛选是 `true`
- 重新请求失败后重试也是 `true`

这样的问题是：
- 首开和刷新会共享同一种 UI
- 用户一切筛选，页面就重新空掉
- 原本已经稳定的内容树会被反复拆掉再建

本次的结论很明确：
- `bootstrapping` 只出现一次，负责首开。
- `isRefreshing` 可以出现多次，但不允许清空旧内容。

## 6. SwiftUI 可运行示例
```swift
import SwiftUI

@MainActor
@Observable
final class DemoTimelineViewModel {
    enum BootstrapPhase {
        case bootstrapping
        case ready
    }

    var items: [String] = []
    var bootstrapPhase: BootstrapPhase = .bootstrapping
    var isRefreshing = false
    private var hasResolvedInitialSnapshot = false

    func loadInitialData() async {
        guard !hasResolvedInitialSnapshot else { return }
        async let timeline = fetchTimeline()
        async let markers = fetchMarkers()
        _ = await (timeline, markers)
        items = await timeline
        hasResolvedInitialSnapshot = true
        bootstrapPhase = .ready
    }

    func refresh() async {
        guard hasResolvedInitialSnapshot else {
            await loadInitialData()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        items = await fetchTimeline()
    }

    private func fetchTimeline() async -> [String] {
        try? await Task.sleep(for: .milliseconds(300))
        return ["书摘 A", "书评 B", "相关内容 C"]
    }

    private func fetchMarkers() async -> [Date] {
        try? await Task.sleep(for: .milliseconds(180))
        return [Date()]
    }
}

struct DemoTimelinePage: View {
    let viewModel: DemoTimelineViewModel?

    var body: some View {
        Group {
            if let viewModel {
                if viewModel.bootstrapPhase == .ready {
                    List(viewModel.items, id: \.self) { item in
                        Text(item)
                    }
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isRefreshing {
                            Text("正在更新")
                                .padding(8)
                        }
                    }
                } else {
                    DemoBootstrapShell()
                }
            } else {
                DemoBootstrapShell()
            }
        }
    }
}

private struct DemoBootstrapShell: View {
    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.12))
                .frame(height: 280)
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.10))
                .frame(height: 120)
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.gray.opacity(0.10))
                .frame(height: 120)
        }
        .padding()
    }
}
```

## 7. Compose 对照示例
```kotlin
sealed interface TimelineUiPhase {
    data object Bootstrapping : TimelineUiPhase
    data object Ready : TimelineUiPhase
}

data class TimelineUiState(
    val phase: TimelineUiPhase = TimelineUiPhase.Bootstrapping,
    val items: List<String> = emptyList(),
    val isRefreshing: Boolean = false,
)

@Composable
fun TimelinePage(state: TimelineUiState) {
    when (state.phase) {
        TimelineUiPhase.Bootstrapping -> TimelineBootstrapShell()
        TimelineUiPhase.Ready -> {
            Box {
                LazyColumn {
                    items(state.items) { item ->
                        Text(text = item)
                    }
                }
                if (state.isRefreshing) {
                    Text("正在更新", modifier = Modifier.align(Alignment.TopEnd))
                }
            }
        }
    }
}
```

## 8. 给 Android Compose 开发者的迁移提醒
- 不要把 pager 预创建误当作完整的预热方案。预热失败时页面怎么展示，才是决定体验上限的关键。
- 不要在首次加载时过早暴露真实空态。只有确认首屏查询已经完成，空态才有业务语义。
- 不要把 `loading` 作为一个笼统的 Bool 使用。首开和刷新需要不同的视觉策略。
- 不要让容器和页面同时各自创建一份状态源。时间线这类页面一旦分页、筛选、预取并存，状态所有权必须非常清楚。

## 9. 最终结论
- 这次时间线体验提升的核心不是“请求更早发出去了”，而是“首帧就给出稳定结构”。
- Android -> iOS 迁移时，业务意图应该理解成：
  - 用户要的是稳定浏览时间线。
  - 不是看一个更花哨的 loading 页面。
- 如果后续 Android 也要优化首开体验，优先吸收这三个原则：
  - 静态壳层
  - 首屏快照原子提交
  - 首开与刷新状态分离
