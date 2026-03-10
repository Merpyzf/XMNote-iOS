# ExpandableRichText 使用说明

## 组件定位
- 源码路径：
  - `xmnote/UIComponents/Foundation/ExpandableRichText.swift`
  - `xmnote/UIComponents/Foundation/RichText.swift`
  - `xmnote/UIComponents/Foundation/CollapsedRichTextPreview.swift`
- 角色：列表 / 卡片中的 HTML 富文本展示组件。
- 设计目标：在保留完整 HTML 展示能力的前提下，优先降低长文本在滚动列表中的测量和绘制成本。

## 快速接入
```swift
ExpandableRichText(
    html: event.content,
    baseFont: TimelineTypography.eventRichTextBaseFont,
    lineSpacing: TimelineTypography.eventRichTextLineSpacing
)
```

如果需要完整富文本、不需要展开收起，可直接使用低层 `RichText`：

```swift
RichText(
    html: html,
    baseFont: .preferredFont(forTextStyle: .body),
    textColor: .label,
    lineSpacing: 4,
    maxLines: 0
)
```

## 参数说明

### ExpandableRichText
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `html` | `String` | 无 | 需要展示的 HTML 字符串。 |
| `baseFont` | `UIFont` | `.preferredFont(forTextStyle: .body)` | 正文基准字体。 |
| `textColor` | `UIColor` | `.label` | 正文主色。 |
| `lineSpacing` | `CGFloat` | `4` | 段内行距。 |
| `maxLines` | `Int` | `3` | 收起态最大显示行数。 |

### RichText
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `html` | `String` | 无 | 需要展示的 HTML 字符串。 |
| `baseFont` | `UIFont` | `.preferredFont(forTextStyle: .body)` | 正文字体。 |
| `textColor` | `UIColor` | `.label` | 文本颜色。 |
| `lineSpacing` | `CGFloat` | `4` | 行距。 |
| `maxLines` | `Int` | `0` | `0` 表示不限制；大于 `0` 时启用原生尾部省略号截断。 |
| `onTruncationChanged` | `((Bool) -> Void)?` | `nil` | 截断状态变化回调。 |

### CollapsedRichTextPreview
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `html` | `String` | 无 | 预览态 HTML 文本。 |
| `baseFont` | `UIFont` | 无 | 预览态基准字体。 |
| `textColor` | `UIColor` | 无 | 预览态文本颜色。 |
| `lineSpacing` | `CGFloat` | 无 | 预览态行距。 |
| `maxLines` | `Int` | 无 | 收起态最大显示行数。 |
| `onExpand` | `() -> Void` | 无 | 点击“展开”后的回调。 |

## 示例

### 示例 1：时间线书摘卡片接入
```swift
ExpandableRichText(
    html: event.content,
    baseFont: TimelineTypography.eventRichTextBaseFont,
    lineSpacing: TimelineTypography.eventRichTextLineSpacing
)
.equatable()
```

### 示例 2：引用色较浅的附加说明
```swift
ExpandableRichText(
    html: event.idea,
    baseFont: TimelineTypography.eventRichTextBaseFont,
    textColor: .secondaryLabel,
    lineSpacing: TimelineTypography.eventRichTextLineSpacing,
    maxLines: 3
)
```

### 示例 3：只用低层 `RichText` 做完整展示
```swift
RichText(
    html: noteDetailHTML,
    baseFont: .preferredFont(forTextStyle: .body),
    textColor: .label,
    lineSpacing: 6,
    maxLines: 0,
    onTruncationChanged: nil
)
```

## 常见问题

### 1. 为什么收起态不用完整 `UITextView`？
完整 `UITextView + NSLayoutManager` 在长列表里会带来更高的测量和绘制成本。当前收起态改用 `UILabel`，并复用共享缓存，目标是优先保证滚动流畅度。

### 2. 为什么收起态没有引用竖线和自定义列表圆点？
这是有意的性能取舍。用户当前不需要这两类视觉元素，去掉后可以直接使用系统级别的尾部省略号截断，并显著降低列表场景的排版成本。

### 3. 省略号是手工拼接的吗？
不是。收起态和 `RichText(maxLines > 0)` 都依赖系统原生的尾部截断能力，省略号由系统文本排版提供。
