# RichTextEditor/
> L2 | 父级: /CLAUDE.md

富文本编辑器功能模块。基于 UITextView 桥接 SwiftUI，支持 HTML 往返序列化。
功能模块定位，不整体迁入 UIComponents；仅纯展示且跨页面复用的子组件允许抽取。

## 成员清单

- `RichTextEditor.swift`: SwiftUI 入口组件，UIViewRepresentable 桥接
- `RichTextEditorView.swift`: UITextView 子类，自定义输入行为
- `RichTextBridge.swift`: SwiftUI ↔ UIKit 状态桥接层
- `RichTextCoordinator.swift`: UITextViewDelegate 实现，格式追踪与同步；UIKit 字符串使用 `String(localized:)` 支持本地化
- `RichTextLayoutManager.swift`: 自定义 NSLayoutManager，引用块与列表渲染
- `RichTextToolbar.swift`: 格式工具栏 UI
- `RichTextFormat.swift`: RichTextFormat 枚举（bold/italic/underline 等 8 种格式）
- `HTMLParser.swift`: HTML → NSAttributedString 解析器
- `HTMLSerializer.swift`: NSAttributedString → HTML 序列化器
- `HighlightColors.swift`: ARGB 高亮色值映射表与 UIColor 转换

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
