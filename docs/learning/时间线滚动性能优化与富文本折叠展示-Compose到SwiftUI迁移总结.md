# 时间线滚动性能优化与富文本折叠展示（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- `LazyVStack(pinnedViews: [.sectionHeaders])` 是做时间线粘性日期头的正确语义入口，不能为了局部性能把它替换成普通 overlay。
- SwiftUI 列表性能问题很多时候不是“单个 View 太重”，而是“观察边界太大”，导致无关状态把整棵子树一起刷新。
- `UIViewRepresentable` 在列表中可用，但前提是把“完整态”和“预览态”拆成不同渲染通道，避免所有 cell 都走最重的 UIKit 排版路径。
- `UILabel` 自带系统尾部省略号截断；当需求只剩“多行截断 + 省略号”时，优先用系统能力，不要继续维持复杂自绘。
- 共享缓存不只是缓存数据，也要缓存“宽度 + 行数约束”下的布局结果，否则滚动时仍会重复测量。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 缩小重组范围 | `derivedStateOf`、state hoisting | 拆分 `TimelineCalendarPanel` 与列表热区 | 先缩观察边界，再谈局部微优化 |
| 粘性分组头 | `LazyColumn(stickyHeader)` | `LazyVStack(pinnedViews: [.sectionHeaders])` | 使用容器原生语义，不手搓吸顶 |
| 长文本折叠 | `Text(maxLines, overflow)` + 条件展开 | `CollapsedRichTextPreview` + `ExpandableRichText` | 列表态走轻量文本，完整态再走重排版 |
| 布局结果复用 | remember + measure cache | `RichTextRenderCache` 缓存 attributed string 与 layout snapshot | 缓存要覆盖“内容”和“尺寸”两层 |
| 列表 diff 降载 | 稳定 key + 最小 state 写入 | `sectionsRevision` + `applySections` | 只有数据真的变化时才更新列表状态 |

## 3. 这次优化到底做对了什么

### 3.1 拆观察边界，而不是把所有逻辑塞进一个大 View
时间线页面同时包含：
- HorizonCalendar 桥接层
- 顶部月份/日期状态
- 列表 section 数据
- 富文本卡片

如果这些都挂在同一观察热区里，列表滚动或 sections 变化时，日历桥接层也会跟着重刷。

本次做法：
- `ReadingTimelineContentView` 只负责容器拼装。
- `TimelineCalendarPanel` 只观察 `selectedDate / displayedMonthStart / markerRevision`。
- 列表容器单独观察 `sections / sectionsRevision / isLoading`。

这和 Compose 里的 state hoisting 是同一个原则：
不要让“不相关的状态”进入同一个可重组边界。

### 3.2 粘性头必须保留系统语义
之前性能优化里最容易犯的错，是为了减少层级而破坏 `Section` 语义，结果把粘性头做没了。

本次最终结论：
- 时间线日期头必须继续挂在 `Section(header:)` 上。
- 性能优化应该发生在 section 内部 item 和状态边界上，而不是破坏 `pinnedViews` 本身。

这和 Compose 的经验一致：
`stickyHeader` 的问题通常不该通过“去掉 stickyHeader”解决，而应该回到 item diff、子树测量和状态范围。

### 3.3 富文本要拆成“完整态”和“列表预览态”两条通道
原始问题不在“能不能显示 HTML”，而在“列表里每个 item 都用完整 HTML 排版是否值得”。

本次策略：
- 展开态：`RichText`
  - `UITextView + RichTextLayoutManager`
  - 保留完整 HTML 排版能力
- 收起态：`CollapsedRichTextPreview`
  - `UILabel`
  - 系统尾部省略号
  - 不再支持引用竖线与自定义列表圆点

关键不是 UIKit 还是 SwiftUI，而是：
列表滚动时，大多数 cell 只需要“快速看到 3 行摘要”。
如果还让这些 cell 走完整排版链路，卡顿就是必然结果。

## 4. 为什么系统级省略号比手工拼接更合适
手工拼接 `...` 的常见问题：
- 不知道真实截断位置。
- 字体、字距、换行策略一变，截断位置就失准。
- 多语言和不同屏宽下容易出现“多一个字”或“少一行”。

这次直接改为系统级尾部截断：
- `UILabel.numberOfLines = maxLines`
- `UILabel.lineBreakMode = .byTruncatingTail`
- `UITextView.textContainer.maximumNumberOfLines = maxLines`
- `UITextView.textContainer.lineBreakMode = .byTruncatingTail`

结论很直接：
如果需求只是“多行收起 + 省略号”，系统能力比手工实现更稳定，也更便宜。

## 5. 稳定 identity 和 revision token 的价值
列表性能差不只是因为排版重，也常见于“状态写太勤”。

本次在 `TimelineViewModel` 里做了两件事：
- `applySections(_:)` 只有在 `newSections != sections` 时才真正写回
- 额外维护 `sectionsRevision`

作用：
- 避免每次刷新都让 SwiftUI 重新比较整组 section 深层结构。
- 用轻量 revision token 描述“列表确实变了”，而不是把整棵数据树都拖进 diff。

这和 Compose 中常见的“稳定 key + 不重复写相同 state”完全一致。

## 6. SwiftUI 可运行示例
```swift
import SwiftUI

struct TimelineSectionModel: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [String]
}

@Observable
@MainActor
final class TimelineDemoViewModel {
    var sections: [TimelineSectionModel] = []
    private(set) var sectionsRevision: Int = 0

    func applySections(_ newSections: [TimelineSectionModel]) {
        guard newSections != sections else { return }
        sections = newSections
        sectionsRevision &+= 1
    }
}

struct TimelineDemoView: View {
    @State private var viewModel = TimelineDemoViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(viewModel.sections) { section in
                    Section {
                        VStack(spacing: 12) {
                            ForEach(section.items, id: \.self) { item in
                                CollapsedPreviewText(text: item)
                                    .padding(12)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                            }
                        }
                        .padding(.bottom, 12)
                    } header: {
                        Text(section.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground))
                    }
                }
            }
            .padding()
        }
        .task {
            viewModel.applySections([
                .init(id: "2026-03-10", title: "03.10 2026", items: [
                    "这是一段很长很长的文本，用来模拟列表收起态。",
                    "第二条内容同样只展示摘要，不在滚动中做完整富文本排版。"
                ])
            ])
        }
    }
}

private struct CollapsedPreviewText: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

## 7. Compose 对照示例
```kotlin
@Composable
fun TimelineDemo(sections: List<TimelineSection>) {
    LazyColumn {
        sections.forEach { section ->
            stickyHeader {
                Text(
                    text = section.title,
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White)
                        .padding(vertical = 8.dp)
                )
            }
            items(section.items, key = { it.id }) { item ->
                Text(
                    text = item.preview,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(12.dp)
                        .background(Color.White, RoundedCornerShape(16.dp))
                        .padding(12.dp)
                )
            }
        }
    }
}
```

## 8. 给 Android Compose 开发者的迁移提醒
- 不要把 SwiftUI 的 `@Observable` 当成“随便写都便宜”的状态容器。它和 Compose 一样，写入范围直接决定刷新范围。
- 不要在列表收起态执着保留全部富文本语义。先问自己：用户在滚动时到底需要看到什么。
- 不要为了性能破坏系统容器语义。`stickyHeader` / `pinnedViews` 这种能力，应该被保留，然后去优化其内部内容。

## 9. 最终结论
- 这次优化的核心，不是“把 SwiftUI 换成 UIKit”，而是“只在真正需要完整能力的地方使用重排版”。
- Android -> iOS 迁移时，应该优先对齐业务意图：
  - 用户要的是流畅浏览时间线。
  - 不是每个 cell 都 100% 保留富文本高级装饰。
- 当需求已经明确不要引用竖线和自定义列表圆点时，系统级截断就是最合理的实现路径。
