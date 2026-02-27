# 热力图空方格月份缺失修复总结（Android Compose → SwiftUI）

## 1. 问题现象
- iOS 热力图中，左侧“无活动方格”顶部不显示月份标签。
- 预期：即便是无活动方格，只要列首日期发生月份交接，也应显示月份。

## 2. 根因分析
- 之前实现将左侧补齐列建模为“虚拟 padding 列”，这类列没有真实日期。
- 月份标签计算依赖列首日期与前列首日期，padding 列无法参与计算，所以标签被清空。
- Android 参考实现是“所有列都有真实日期”，月份标题由日期交接触发，不依赖是否有活动数据。

## 3. iOS 修复要点
- 删除虚拟 padding 列，改为“向前扩展真实日期周列”。
- 每个显示列都具备完整 7 天日期；无活动仅体现在颜色等级为 `none`，不影响月份交接判断。
- 月份显示规则维持：
  - 首列显示 `M月`
  - 同年交接显示 `M月`
  - 跨年交接显示 `yy年M月`

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct RealDateColumnsDemo: View {
    let calendar = Calendar.current
    let visibleWeeks = 8
    let realWeeks = 3

    var body: some View {
        let synthetic = max(0, visibleWeeks - realWeeks)
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -7 * (visibleWeeks - 1), to: end)!
        let columns = buildColumns(start: start, count: visibleWeeks)

        HStack(spacing: 3) {
            ForEach(columns.indices, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(monthLabel(i: i, columns: columns) ?? "")
                        .font(.system(size: 9))
                        .frame(height: 16)
                    ForEach(columns[i], id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(i < synthetic ? .gray.opacity(0.25) : .green.opacity(0.5))
                            .frame(width: 13, height: 13)
                    }
                }
            }
        }
    }

    func buildColumns(start: Date, count: Int) -> [[Date]] {
        (0..<count).map { w in
            (0..<7).map { d in
                calendar.date(byAdding: .day, value: w * 7 + d, to: start)!
            }
        }
    }

    func monthLabel(i: Int, columns: [[Date]]) -> String? {
        let current = columns[i][0]
        let m = calendar.component(.month, from: current)
        let y = calendar.component(.year, from: current)
        guard i > 0 else { return "\(m)月" }
        let prev = columns[i - 1][0]
        let pm = calendar.component(.month, from: prev)
        let py = calendar.component(.year, from: prev)
        guard m != pm || y != py else { return nil }
        return y != py ? String(format: "%02d年%d月", y % 100, m) : "\(m)月"
    }
}
```

## 5. Compose 对照思路
- Compose 也应优先使用“真实日期列补齐”而非 UI 级虚拟占位列。
- 让 `LazyRow` 每个 item 都持有 `weekStartDate`，月份标签由 `weekStartDate` 与前一项比较决定。

## 6. 迁移结论
- “无数据”与“无日期”是两件事：热力图可无数据，但不应无日期。
- 只要月份规则依赖日期交接，就必须保证所有可见列都具备真实日期语义。
