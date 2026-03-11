# 在读首页仪表盘卡片与弧形进度（Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- 首页仪表盘不是“一个大 View 里拼很多 `if`”，而是“页面壳层 + 页面私有卡片 + 仓储聚合 + 格式化工具”四层拆分。
- SwiftUI 里做首页类概览页时，优先让 Repository 输出聚合快照，而不是让 ViewModel 一边拿多路数据一边自己拼口径。
- 当主值文本需要品牌数字字体时，数字和单位最好拆成分段模型，再在视图层组合 `AttributedString`，而不是直接拼一个完整字符串硬调字重。
- 弧形进度条如果需要稳定几何，必须基于正方形画布计算；一旦让它跟随非正方形容器拉伸，视觉会立刻变形。
- 小型趋势图不能只靠线性比例，否则极差场景下的小值完全不可读；要对短区间做最小可视高度补偿。

## 2. Compose -> SwiftUI 思维对照
| 目标 | Android / Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
| --- | --- | --- | --- |
| 首页聚合数据 | `Presenter/ViewModel` 手动拉多路数据 | `ReadingDashboardRepository.observeDashboard()` 输出首页快照 | 先聚合，再渲染 |
| 页面卡片拆分 | 多个 `include` / adapter item / composable block | `ReadingDashboardCards.swift` 页面私有组件集合 | 页面私有组件不要过早抽成公共组件 |
| 数字 + 单位混排 | `SpannableString` / `AnnotatedString` | `ReadingDashboardMetricValueDisplay` + `AttributedString` | 先表达语义段，再做样式 |
| 弧形进度 | `Canvas` / 自定义 `drawArc` | `Shape.path(in:)` + 正方形画布 | 几何优先于容器拉伸 |
| 小值可见性 | 最小高度 / 非线性映射 | `displayedBarRatio` 的 gamma + floor 映射 | 图表不是纯数学，要照顾可读性 |

## 3. 这次做对的关键点

### 3.1 首页聚合一定要下沉到 Repository
Android 老页面里很多首页统计是 Presenter 主动刷新、局部更新拼出来的。

这次 iOS 选择：
- `ReadingDashboardRepository` 直接输出 `ReadingDashboardSnapshot`
- 里面一次性带出：
  - 今日目标
  - 三项趋势
  - 继续阅读
  - 最近在读
  - 年度摘要

好处很直接：
- ViewModel 不需要知道每项数据怎么查。
- 页面不会出现“某张卡更新了，另一张卡还停留旧值”的局部不一致。
- 目标修改后只要 observation 回流，整页自然同步。

### 3.2 页面私有卡片不要急着公共化
`ReadingTrendMetricsSection`、`ReadingFeatureCardsSection`、`ReadingRecentBooksCard` 这些组件虽然拆了文件，但仍然留在 `Views/Reading/Components`。

原因不是偷懒，而是边界正确：
- 它们服务的是“在读首页”这个页面的完整叙事。
- 如果提前迁到 `UIComponents`，很容易把业务语义和视觉规则误包装成“全局可复用组件”。

这和 Compose 中“先局部 composable，确认跨页面复用后再抽公共 module”是同一个原则。

### 3.3 弧形进度条不是圆越大越舒服，而是几何比例要稳定
这次“今日阅读”组件反复调过一轮，核心结论是：
- 弧环必须基于正方形绘制。
- 中轴主值宽度要受控，不然品牌数字一长就会把环挤爆。
- 目标文本应该挂在底部缺口区域，而不是随便塞在圆心下方。

如果你只从容器尺寸倒推出一个圆弧，很容易出现：
- 两侧空洞过大
- 中轴文本不在视觉中心
- 目标文案和弧顶、标题互相打架

### 3.4 趋势图要兼顾真实比例和可读性
线性映射是“数学正确”，但不一定“界面可读”。

本次首页条形图做了两层处理：
- 0 值保留 0 高度
- 极小非 0 值进入短区间映射时抬高到最小可视比例

这和 Compose 里给 `Modifier.height()` 加最小值是一个思路，只是 SwiftUI 这里把它系统化成了格式化工具的一部分。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct MetricValueDisplay {
    struct Segment: Identifiable {
        enum Role {
            case number
            case unit
        }

        let id = UUID()
        let text: String
        let role: Role
    }

    let segments: [Segment]
}

struct ArcGaugeDemo: View {
    let progress: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                ArcShape(progress: 1)
                    .stroke(.gray.opacity(0.2), style: .init(lineWidth: 8, lineCap: .round))

                ArcShape(progress: progress)
                    .stroke(.green, style: .init(lineWidth: 8, lineCap: .round))

                Text("42:18")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .offset(y: -2)
            }
            .frame(width: 160, height: 160)

            Text("目标 60 分钟")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

struct ArcShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard progress > 0 else { return Path() }
        let radius = min(rect.width, rect.height) / 2
        let start = Angle.degrees(135)
        let end = Angle.degrees(135 + 270 * progress)

        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: start,
            endAngle: end,
            clockwise: false
        )
        return path
    }
}
```

## 5. Compose 对照示例
```kotlin
@Composable
fun DailyGoalArc(progress: Float, readingText: String, targetText: String) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(
            modifier = Modifier.size(160.dp),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.matchParentSize()) {
                val start = 135f
                val sweep = 270f
                val stroke = 8.dp.toPx()
                drawArc(
                    color = Color.LightGray.copy(alpha = 0.2f),
                    startAngle = start,
                    sweepAngle = sweep,
                    useCenter = false,
                    style = Stroke(width = stroke, cap = StrokeCap.Round)
                )
                drawArc(
                    color = Color(0xFF2ECF77),
                    startAngle = start,
                    sweepAngle = sweep * progress,
                    useCenter = false,
                    style = Stroke(width = stroke, cap = StrokeCap.Round)
                )
            }
            Text(text = readingText)
        }
        Text(text = targetText, color = Color.Gray, fontSize = 12.sp)
    }
}
```

## 6. 给 Android Compose 开发者的迁移提醒
- 不要把 Presenter 时代的“手动刷新局部卡片”习惯直接带到 SwiftUI。首页类页面更适合先做聚合快照，再让页面自然回流。
- 不要因为 SwiftUI 很容易拆 View，就把所有页面私有卡片提前抽成公共组件。先判断业务边界，再决定目录归属。
- 做图表和弧环时，不要只看比例公式，要先看用户是否还能读懂。UI 里的“可见”比“绝对精确”更重要。

## 7. 最终结论
- 这次在读首页的核心不是“把 Android 阅读页搬到 iOS”，而是把 Android 的业务意图重组成一个更适合 iOS 首页浏览的仪表盘。
- 迁移时最重要的不是控件长得像不像，而是：
  - 数据是不是同一口径
  - 页面节奏是不是更清楚
  - 交互是不是更符合当前平台的使用场景
