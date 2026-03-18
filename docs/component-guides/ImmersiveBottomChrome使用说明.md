# ImmersiveBottomChrome 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/ImmersiveBottomChrome.swift`
- 角色：为全屏查看类页面提供统一的底部沉浸渐变、悬浮 ornament 承载、滚动补偿与安全区覆盖。
- 边界：组件只负责底部视觉托底与悬浮交互容器，不负责顶部栏、不负责页面业务动作，也不直接生成玻璃按钮内容。

## 快速接入
```swift
@State private var bottomOrnamentHeight: CGFloat = 0

GeometryReader { proxy in
    let metrics = ImmersiveBottomChromeMetrics.make(
        measuredOrnamentHeight: bottomOrnamentHeight,
        safeAreaBottomInset: proxy.safeAreaInsets.bottom
    )

    content
        .overlay(alignment: .bottom) {
            ImmersiveBottomChromeOverlay(metrics: metrics) {
                GlassEffectContainer(spacing: Spacing.base) {
                    HStack(spacing: Spacing.base) {
                        HStack(spacing: Spacing.cozy) {
                            ImmersiveBottomChromeIcon(systemName: "tag")
                            ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                        }
                        .padding(.horizontal, Spacing.base)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
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
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            bottomOrnamentHeight = height
        }
}
```

## 参数说明
### `ImmersiveBottomChromeMetrics.make(...)`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `measuredOrnamentHeight` | `CGFloat` | 无 | 页面实际测得的底部操作区高度。 |
| `safeAreaBottomInset` | `CGFloat` | 无 | 当前页面底部安全区，用于覆盖手势导航条区域。 |
| `ornamentMinimumTouchHeight` | `CGFloat` | `44` | 交互热区最小高度基线。 |
| `ornamentTopPadding` | `CGFloat` | `Spacing.cozy` | ornament 与渐变顶部的分隔。 |
| `minimumBottomPadding` | `CGFloat` | `Spacing.contentEdge` | 底部最小保底留白。 |
| `readableInsetExtra` | `CGFloat` | `Spacing.base` | 正文尾部额外可读缓冲。 |
| `scrollIndicatorInsetCompensation` | `CGFloat` | `Spacing.cozy` | 滚动条 inset 的回收补偿。 |
| `gradientMinimumHeight` | `CGFloat` | `120` | 渐变最小高度。 |
| `gradientExtraHeight` | `CGFloat` | `Spacing.section` | 在 ornament 高度基础上的附加渐变高度。 |

### `ImmersiveBottomChromeOverlay`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `metrics` | `ImmersiveBottomChromeMetrics` | 无 | 底部渐变和可读留白的统一快照。 |
| `surfaceColor` | `Color` | `.surfacePage` | 渐变落点颜色，通常与页面底色一致。 |
| `horizontalPadding` | `CGFloat` | `Spacing.screenEdge` | ornament 水平外边距。 |
| `ornamentTopPadding` | `CGFloat` | `Spacing.cozy` | ornament 与渐变顶部的垂直距离。 |
| `ornament` | `ViewBuilder` | 无 | 具体业务操作区内容，通常是 glassEffect 按钮组。 |

### `ImmersiveBottomChromeIcon`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `systemName` | `String` | 无 | SF Symbols 图标名。 |
| `foregroundStyle` | `Color` | `.textPrimary` | 图标前景色；删除等危险操作可显式传错误色。 |

## 示例
### 示例 1：书摘查看底部分享/编辑/删除
```swift
ImmersiveBottomChromeOverlay(metrics: metrics) {
    GlassEffectContainer(spacing: Spacing.base) {
        HStack(spacing: Spacing.base) {
            HStack(spacing: Spacing.cozy) {
                ImmersiveBottomChromeIcon(systemName: "tag")
                ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                ImmersiveBottomChromeIcon(systemName: "square.and.arrow.up")
            }
            .padding(.horizontal, Spacing.base)
            .glassEffect(.regular.interactive(), in: .capsule)

            ImmersiveBottomChromeIcon(
                systemName: "trash",
                foregroundStyle: .feedbackError
            )
            .glassEffect(.regular.interactive(), in: .circle)
        }
    }
}
```

### 示例 2：页内滚动补偿
```swift
ScrollView {
    VStack { ... }
    Color.clear.frame(height: max(Spacing.base, metrics.readableInset))
}
.contentMargins(.bottom, Spacing.none, for: .scrollContent)
.contentMargins(.bottom, metrics.scrollIndicatorInset, for: .scrollIndicators)
.ignoresSafeArea(.container, edges: .bottom)
```

## 常见问题
### 1) 为什么渐变要 `ignoresSafeArea(edges: .bottom)`？
因为目标是把半透明托底延展到手势导航条区域，避免底部安全区内出现一截没有被覆盖的断层。

### 2) 为什么不用 `safeAreaInset(edge: .bottom)`？
这次需求是“底部工具栏保持 iOS 风格悬浮 ornament，不改成托管底栏”。`safeAreaInset` 会把内容整体顶起，不符合沉浸式查看页目标。

### 3) 为什么需要 `HeightPreferenceKey` 回写 ornament 高度？
滚动正文的尾部可读留白、滚动条 inset、渐变高度都依赖真实 ornament 高度；直接写死会在按钮数量变化或 Dynamic Type 下失准。

### 4) 哪些页面适合复用这个组件？
适合“顶部保持标准导航栏，底部需要悬浮操作区，同时正文希望沉浸延展到安全区”的查看类页面，例如书摘查看、书评查看、相关内容查看。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
