# 热力图月份交接显示与星期垂直居中总结（Android Compose → SwiftUI）

## 1. 问题与纠偏
- 误差 1：把“月份交接显示”误实现成“每周都显示月份”。
- 误差 2：右侧星期列与网格行中心存在垂直偏移。
- 对齐目标（Android 业务语义）：
  - 月份只在交接列显示（包括首列、跨年列）。
  - 星期文本要与对应方格行中心对齐。

## 2. iOS 关键知识点
- 月份显示应基于“列首日期与前列首日期是否跨月/跨年”判断，而不是基于“每列都输出文案”。
- SwiftUI `VStack(spacing:)` 会作用于所有相邻子项：
  - 若把“顶部月份占位行 + 星期行”放在同一个 `VStack(spacing: squareSpacing)`，会在顶部占位与首行之间引入额外间距，导致整体下移。
  - 正确做法：外层 `VStack(spacing: 0)` 管“顶部占位 + 行容器”，内层行容器 `VStack(spacing: squareSpacing)` 管 7 行。

## 3. Android Compose 对照思路
- Android Canvas 版本 `drawColumnHeader` 本质是“交接触发”，并非“每周必画”。
- Compose 中可用同样的纯函数规则：
  - 输入当前列首日与前列首日；
  - 输出 `null / M月 / yy年M月`。
- 垂直对齐同理：顶部占位与行容器分层，避免把 header-gap 混入 row-gap。

## 4. SwiftUI 可运行示例
```swift
import SwiftUI

struct HeaderRuleDemo: View {
    let weekStarts: [Date]
    let calendar = Calendar.current

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weekStarts.indices, id: \.self) { i in
                let text = labelText(
                    current: weekStarts[i],
                    previous: i > 0 ? weekStarts[i - 1] : nil
                )
                Color.clear
                    .frame(width: 13, height: 16)
                    .overlay {
                        if let text {
                            Text(text)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.2)
                                .frame(width: 13)
                        }
                    }
            }
        }
    }

    func labelText(current: Date, previous: Date?) -> String? {
        let m = calendar.component(.month, from: current)
        let y = calendar.component(.year, from: current)
        guard let previous else { return "\(m)月" }
        let pm = calendar.component(.month, from: previous)
        let py = calendar.component(.year, from: previous)
        guard m != pm || y != py else { return nil }
        return y != py ? "\(y % 100)年\(m)月" : "\(m)月"
    }
}
```

## 5. Compose 可运行示例
```kotlin
fun monthLabel(curr: LocalDate, prev: LocalDate?): String? {
    if (prev == null) return "${curr.monthValue}月"
    val monthChanged = curr.monthValue != prev.monthValue || curr.year != prev.year
    if (!monthChanged) return null
    return if (curr.year != prev.year) "${curr.year % 100}年${curr.monthValue}月" else "${curr.monthValue}月"
}
```

## 6. 迁移结论
- 先对齐“业务触发条件”，再调视觉样式；否则很容易出现“看起来更满但语义错了”。
- 垂直对齐问题优先检查“容器分层与 spacing 归属”，不是先调魔法偏移量。
