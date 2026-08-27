# XMSheetScaffold 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Sheet/XMSheetScaffold.swift`。
- 角色：通用业务 Sheet 根骨架，统一标题与静态/动态副标题层级、关闭或双侧操作、全轴回弹，以及可选固定内容顶栏/底栏。
- 适用场景：Book、Tag、Settings 等模块中具有标准标题栏和滚动内容的业务 Sheet。
- 边界：不持有业务状态、不执行保存、不访问 Repository；不替代系统选择器、中心 Alert 或只包含单一短操作的系统弹层。

## 快速接入

```swift
struct ExampleSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "选择标签",
            subtitle: "可多选",
            onClose: { dismiss() }
        ) {
            LazyVStack(spacing: Spacing.none) {
                // 业务内容
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }
}
```

Scaffold 已经提供 `ScrollView`、隐藏滚动条和 `.scrollBounceBehavior(.always)`，调用方不要再套第二层同轴滚动容器。

标题与副标题固定使用 `Spacing.micro`（3pt）组成同一信息组。动态副标题与静态 `subtitle` 都由 scaffold 统一施加 `AppTypography.caption2`、`Color.textSecondary` 和单行限制，业务调用方不要重复覆盖。

## 参数说明

| 参数或槽位 | 类型 | 说明 |
| --- | --- | --- |
| `title` | `String` | 居中主标题，单行显示。 |
| `subtitle` | `String?` | 可选短副标题，单行显示。 |
| `titleSubtitle` | `ViewBuilder` | 动态或可交互副标题；保持具体 View 泛型，由 scaffold 统一副标题样式。当前与 `contentTopBar`、`bottomBar` 组合使用。 |
| `onClose` | `() -> Void` | 标准关闭按钮动作；自定义双侧操作时仍用于外部关闭语义。 |
| `closeVisualSize` | `CGFloat` | 标准关闭按钮的视觉容器尺寸；交互热区始终保持至少 44pt。 |
| `leadingAction` / `trailingAction` | `ViewBuilder` | 需要取消/保存等双侧文本操作时使用。 |
| `contentTopBar` | `ViewBuilder` | 固定在滚动内容上方的筛选或范围控件。 |
| `bottomBar` | `ViewBuilder` | 固定在滚动内容下方的主要操作区。 |
| `scrollEdgePresentation` | `XMScrollEdgeChromePresentation` | 固定栏与滚动内容的系统边缘表达；默认使用现有 overlaySoft 语义。 |
| `content` | `ViewBuilder` | 业务滚动内容；保持具体 View 泛型，不做类型擦除。 |

## 示例

### 示例 1：固定底部操作

```swift
XMSheetScaffold(
    title: "编辑书摘",
    onClose: { dismiss() },
    bottomBar: {
        primaryAction
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.base)
    }
) {
    editorContent
}
```

保存状态、禁用条件和错误反馈仍由业务页面持有。

### 示例 2：固定内容顶栏

```swift
XMSheetScaffold(
    title: "选择书籍",
    onClose: { dismiss() },
    contentTopBar: {
        scopeSelector
            .padding(.horizontal, Spacing.screenEdge)
    }
) {
    bookList
}
```

### 示例 3：动态可交互副标题

```swift
XMSheetScaffold(
    title: "选择书籍",
    onClose: { dismiss() },
    titleSubtitle: {
        // 该文本以副标题信息展示为主，管理入口低频且非破坏性；保留文字自然命中范围，避免标题栏空白响应点击。
        Button("已选择 \(selectedCount) 本", action: openSelectedBooks)
            .buttonStyle(.plain)
            .accessibilityLabel("已选择 \(selectedCount) 本书")
            .accessibilityHint("查看并管理已选书籍")
    },
    contentTopBar: { searchBar },
    bottomBar: { confirmButton }
) {
    bookList
}
```

只有满足 `AGENTS.md`“点击热区与内联次级文字例外”的副标题，才可像上例保留文字自然命中范围；其他按钮继续达到 `InteractionMetrics.minimumTouchTarget`。零选择等纯信息状态应改为非交互 `Text`，不要保留无动作按钮。

### 示例 4：双侧标题操作

```swift
XMSheetScaffold(
    title: "设置",
    onClose: { dismiss() },
    leadingAction: {
        Button("取消") { dismiss() }
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
    },
    trailingAction: {
        Button("完成") { save() }
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
    }
) {
    settingsContent
}
```

## 常见问题

### 1. 内容本身已经是 `List` 或 `ScrollView` 怎么办？

不要直接嵌套。优先把行内容交给 scaffold 的滚动区；如果业务必须拥有特殊滚动物理，应重新判断它是否适合通用 scaffold，而不是关闭某一层滚动。

### 2. 可以把状态或 ViewModel 传进 scaffold 吗？

不建议。传入已经组合好的 View 槽位和关闭动作即可，业务状态留在功能 Sheet。

### 3. 为什么禁止 `AnyView`？

泛型槽位让 SwiftUI 保留稳定的视图身份和静态类型，也让接口对可用结构更明确。只有具体证据证明泛型无法表达时才重新评估边界。

### 4. 什么时候不用 XMSheetScaffold？

系统文件选择器、照片选择器、分享面板、中心确认弹窗，以及仅补充当前页面短信息的系统 popover，应继续使用各自的系统语义入口。

### 5. 动态副标题可以自己设置字体和间距吗？

不可以。`titleSubtitle` 只提供内容和交互语义，字体、颜色、单行限制及与主标题的 3pt 间距由 scaffold 持有。需要离开这一视觉层级的筛选器、搜索框或分段控件应放入 `contentTopBar`，不能借副标题槽位绕过标题结构。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
