# XMScrollEdgeChrome / XMScrollEdgeWash 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMScrollEdgeChrome.swift`、`xmnote/UIComponents/Foundation/XMScrollEdgeWash.swift`
- 角色：为存在固定顶部栏、底部栏或独立滚动视口的页面提供滚动边缘收口能力。
- 分工：`XMScrollEdgeChrome` 负责固定边缘栏容器；`XMScrollEdgeWash` 负责滚动视口顶部、底部或双向的柔和边界覆盖层。
- 边界：组件不承载业务筛选、搜索执行、滚动位置记忆或导航语义；系统导航栏、系统 Sheet chrome、Liquid Glass TabBar 优先使用系统 `safeAreaBar + scrollEdgeEffectStyle`。

## 快速接入
```swift
XMScrollEdgeChrome(
    edges: .top,
    washStyle: .standard,
    topBar: {
        XMScopeSelector(
            items: scopeItems,
            selection: $selectedScope,
            accessibilityLabel: String(localized: "搜索范围")
        )
        .padding(.horizontal, Spacing.screenEdge)
    }
) {
    ScrollView {
        LazyVStack(spacing: Spacing.card) {
            ForEach(results) { result in
                SearchResultCard(result: result)
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
    }
}
```

## 参数说明
### `XMScrollEdgeChrome`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `presentation` | `XMScrollEdgeChromePresentation` | `.contained` | `.contained` 让固定栏参与布局，滚动内容不进入固定栏下方；`.overlaySoft` 使用系统 `safeAreaBar + scrollEdgeEffectStyle(.soft)`，仅用于系统/Sheet chrome 语义。 |
| `edges` | `Edge.Set` | 根据初始化器推断 | 指定需要处理的边缘。顶部栏对应 `.top`，底部栏对应 `.bottom`，双栏可使用 `[.top, .bottom]`。 |
| `contentSpacing` | `CGFloat` | `Spacing.none` | 固定栏与滚动视口之间的布局间距。业务页优先使用页面既有间距 token。 |
| `washStyle` | `XMScrollEdgeWashStyle` | `.standard` | `.contained` 模式下传给滚动视口的柔化层规格。 |
| `topBar` / `bottomBar` | `ViewBuilder` | 按初始化器可选 | 固定顶部或底部栏内容。 |
| `content` | `ViewBuilder` | 必填 | 通常是 `ScrollView`、`List` 或承载滚动视口的容器。 |

### `XMScrollEdgeWashStyle`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `height` | `CGFloat` | `24` | 柔化层高度。常规列表建议 16-24pt，卡片内滚动可降低到 16pt。 |
| `strength` | `XMScrollEdgeWashStrength` | `.regular` | 可选 `.subtle`、`.regular`、`.prominent`，控制材质与表层渐隐存在感。 |
| `surface` | `XMScrollEdgeWashSurface` | `.page` | 可选 `.page`、`.card`、`.sheet`、`.custom(Color)`，用于匹配承托背景。 |

### `View.xmScrollEdgeWash`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `edges` | `Edge.Set` | `.top` | 指定顶部、底部或双向柔化。 |
| `style` | `XMScrollEdgeWashStyle` | `.standard` | 柔化层视觉规格。 |
| `visibility` | `XMScrollEdgeWashVisibility` | `.automatic` | `.automatic` 随滚动状态显示，`.always` 用于测试和静态预览，`.hidden` 用于临时关闭。 |

## 示例
### 示例 1：固定顶部筛选栏
```swift
XMScrollEdgeChrome(edges: .top) {
    ScopeFilterBar(selection: $scope)
} content: {
    ScrollView {
        ResultsList(results: results)
    }
}
```

### 示例 2：卡片内部双向滚动收口
```swift
ScrollView {
    VStack(spacing: Spacing.sm) {
        ForEach(notes) { note in
            NotePreviewRow(note: note)
        }
    }
    .padding(Spacing.md)
}
.xmScrollEdgeWash(
    edges: [.top, .bottom],
    style: XMScrollEdgeWashStyle(height: 16, strength: .subtle, surface: .card)
)
```

### 示例 3：系统 Sheet chrome
```swift
XMScrollEdgeChrome(
    presentation: .overlaySoft,
    edges: .top,
    topBar: {
        SheetToolbar(title: title)
    }
) {
    ScrollView {
        SheetContent()
    }
}
```

## 常见问题
### 1) 为什么拆成 Chrome 和 Wash？
固定栏容器和边缘柔化层是两个 owner。Chrome 决定内容是否进入栏下方，Wash 只负责滚动视口边界的视觉收口。拆开后可复用于列表、Sheet、卡片内滚动等不同场景。

### 2) `.contained` 和 `.overlaySoft` 怎么选？
业务筛选栏、固定操作栏、卡片内滚动优先 `.contained`，避免内容穿到控件背后。系统导航栏、系统 Sheet 顶部栏等平台 chrome 才使用 `.overlaySoft`。

### 3) Wash 会不会挡住点击或 VoiceOver？
不会。柔化层固定 `allowsHitTesting(false)` 且 `accessibilityHidden(true)`，它只是装饰层，不参与点击和读屏顺序。

### 4) `.automatic` 如何判断显示？
顶部在滚离顶部后显示；底部在内容仍可向下滚动时显示。实现只更新布尔状态，不跟随每一帧 offset 改变强度。

### 5) 什么时候不应该使用？
大面积图片背景、非常小的滚动卡片、需要明确分割线的表单分组、普通卡片装饰和按钮背景都不应使用。Wash 是滚动边缘收口，不是通用毛玻璃组件。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
