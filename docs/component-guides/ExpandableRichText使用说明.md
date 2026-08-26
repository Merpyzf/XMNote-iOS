# ExpandableRichText 使用说明

## 组件定位

- 源码目录：`xmnote/UIComponents/Media/RichText/`。
- `ExpandableRichText`：展开/收起交互与状态边界。
- `CollapsedRichTextPreview`：基于 `UILabel` 的轻量收起态、原生尾部截断与布局快照缓存。
- `RichText`：基于 `UITextView` 的完整 HTML 展示、链接点击与排版缓存。
- 三者共同服务阅读日历和单书工作台；不得删除收起态预览后让长列表全部回退到完整 `UITextView`。

## 快速接入

普通卡片可以让组件自管理展开状态：

```swift
ExpandableRichText(
    html: event.content,
    baseFont: TimelineTypography.eventRichTextBaseFont,
    lineSpacing: TimelineTypography.eventRichTextLineSpacing
)
```

可复用列表必须由外部按稳定内容 ID 保存展开状态：

```swift
ExpandableRichText(
    html: row.note.content,
    isExpanded: $rowState.isContentExpanded,
    accessibilitySubject: "书摘正文",
    previewTapIdentity: row.note.id,
    animatesExpansionInternally: false,
    onContentTap: openDetail
)
```

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `html` | HTML 源文本。 |
| `isExpanded` | 可选外部绑定；列表复用场景必须提供。 |
| `baseFont` / `textColor` / `lineSpacing` | 渲染与测量必须共用的排版输入。 |
| `maxLines` | 收起态最大行数，默认 3。 |
| `actionColor` | 展开/收起操作颜色。 |
| `quoteColor` | 完整富文本引用语义色。 |
| `accessibilitySubject` | 组成“展开书摘正文”等无障碍标签。 |
| `previewTapIdentity` | 参与 Equatable 身份比较，防止复用行沿用错误点击对象。 |
| `animatesExpansionInternally` | 外层已有 snapshot 动画时应设为 `false`，避免双重动画。 |
| `onContentTap` | 正文点击回调；`onPreviewTap` 仅为兼容旧调用保留。 |

`RichText` 额外支持 `maxLines`、`onTruncationChanged` 与 `onContentTap`；`CollapsedRichTextPreview` 只负责预览、测量和上报截断，不拥有展开按钮。

## 示例

### 完整富文本

```swift
RichText(
    html: noteHTML,
    baseFont: NoteExcerptTypography.bodyUIFont,
    textColor: .label,
    lineSpacing: 7,
    maxLines: 0,
    onContentTap: nil
)
```

### 预热收起态布局

当展示 Store 已知最终宽度时，可调用 `RichText.prewarmPreviewLayoutSnapshot(...)` 提前建立缓存；预热参数必须与真实渲染字体、行距、行数和屏幕 scale 完全一致。

## 常见问题

### 为什么收起态不直接使用 RichText？

长列表中的完整 `UITextView` 测量与绘制成本更高。`CollapsedRichTextPreview` 用 `UILabel` 和共享布局快照降低重复排版成本。

### 省略号和截断状态可靠吗？

省略号由系统尾部截断生成；组件根据相同宽度和字体的布局快照上报真实溢出状态，不手工拼接字符。

### 为什么外部 Binding 很重要？

原生或懒加载列表会回收承载视图。若状态只存在视图内部，复用或快照更新后可能丢失；按内容 ID 保存才能稳定恢复。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
