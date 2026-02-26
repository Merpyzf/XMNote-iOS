# iOS26 液态玻璃按钮：Compose 到 SwiftUI 迁移总结

## 1. 本次知识点
- SwiftUI iOS 26 提供 `.glassEffect()` 视图修饰符，可在任意视图上精确渲染液态玻璃效果。
- `.glassEffect(.regular.interactive(), in: .circle)` 实现圆形玻璃按钮，`.interactive()` 变体提供按压高亮反馈。
- **避免使用** `.buttonStyle(.glass)`——它是黑盒样式，系统在 label 外自动叠加 chrome，导致按钮尺寸不可控（详见 `docs/踩坑记录.md#1`）。
- 通过统一组件（图标内容 + `.buttonStyle(.plain)` + `.glassEffect()`）可保证多个页面视觉和触达一致。

## 2. Compose -> SwiftUI 思维映射
- Compose 常见做法：
  - 自定义圆形按钮背景（`CircleShape + blur/alpha`）实现”类玻璃”效果。
- SwiftUI iOS 26 推荐做法：
  - 使用 `.buttonStyle(.plain)` + `.glassEffect(.regular.interactive(), in: .circle)` 实现精确可控的液态玻璃按钮。
  - **不要使用** `.buttonStyle(.glass)`，其尺寸由系统托管，无法精确控制。
  - 使用统一视图组件承载 icon 与点击区域，减少样式分叉。

## 3. 最小可运行示例
```swift
import SwiftUI

struct TopBarActionIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
    }
}

struct DemoView: View {
    var body: some View {
        HStack {
            Spacer()
            Button { } label: {
                TopBarActionIcon(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}
```

## 4. 迁移注意事项
- 业务一致优先：仅替换视觉层，不改按钮原有点击行为与路由。
- 统一性优先：顶部右侧按钮必须共用同一套尺寸、图标权重和样式入口。
- 范围控制：若产品仅要求首页顶部改造，避免影响搜索页或其他非 TopSwitcher 场景。
