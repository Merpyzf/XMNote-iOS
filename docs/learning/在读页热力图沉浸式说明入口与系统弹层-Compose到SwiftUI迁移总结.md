# 在读页热力图沉浸式说明入口与系统弹层（Android Compose -> SwiftUI）迁移总结

## 1. 本次 iOS 知识点
- `CardContainer` 需要支持按场景覆盖视觉参数：通过 `cornerRadius/showsBorder` 可选参数，避免“一刀切描边”让高信息密度区域变脏。
- 沉浸式 info 入口不等于弱可点击性：视觉按钮可以是 `24x24`，但热区应提升到 `32x32`，兼顾克制视觉与可用性。
- 系统 `sheet` 已经提供容器能力，内容层不应再重复 `clip + stroke`，否则会出现双层边界与风格冲突。
- 统计类型切换并入说明弹层正文（`Picker(.segmented)`）可减少一次弹窗跳转，降低认知中断。

## 2. Android Compose -> SwiftUI 思维对照
| 目标 | Android Compose 常见做法 | SwiftUI 本次做法 | 迁移原则 |
|---|---|---|---|
| 卡片风格分场景 | `Card(shape, border)` 每处手工写 | `CardContainer(cornerRadius:showsBorder:)` 参数化复用 | 统一能力，按场景覆盖 |
| 小图标弱化展示 | `IconButton` + 透明背景 | `Button + Image("info.circle")` + 小视觉尺寸 | 视觉弱化，热区保底 |
| 说明面板交互 | BottomSheet + 二次选择弹窗 | 系统 `sheet` 内直接 segmented 切换 | 减少层级与打断 |

## 3. 可运行示例（SwiftUI）
```swift
import SwiftUI

struct HeatmapInfoEntryDemo: View {
    @State private var isPresented = false
    @State private var type: HeatmapStatisticsDataType = .all

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.contentBackground)
                .frame(height: 220)

            Button { isPresented = true } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textHint.opacity(0.82))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .frame(width: 32, height: 32) // 触控热区
            .padding(12)
        }
        .sheet(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 12) {
                Text("热力图说明").font(.title3.weight(.semibold))
                Picker("统计口径", selection: $type) {
                    ForEach(HeatmapStatisticsDataType.allCases) { t in
                        Text(t.title).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                Button("完成") { isPresented = false }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .padding(18)
            .presentationDetents([.medium, .large])
            .presentationBackground(.thinMaterial)
            .presentationCornerRadius(28)
        }
    }
}
```

## 4. 迁移结论
- Android 侧业务意图是“查看说明 + 切换口径”，iOS 侧应使用系统容器表达，而不是把 Android 的视觉结构逐层照搬。
- 当背景与前景已可区分时，优先移除描边，通过留白和层级对比建立边界，画面会更干净。

## 5. 高度策略补充（2026-02-27）
- 在读热力图移除固定 `frame(height:)`，改为由 `HeatmapChart` 内容高度驱动。
- 这与 Android 的意图一致：Android 端 `HistoryChart` 也是由容器测量后绘制网格，不依赖组件内部魔法数高度。
- SwiftUI 场景下若担心父容器拉伸，可用 `.fixedSize(horizontal: false, vertical: true)` 明确“垂直取内容高度”。
