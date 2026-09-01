# AIMarkdownResultView 使用说明

## 组件定位

- 源码路径：`xmnote/UIComponents/Media/Markdown/AIMarkdownResultView.swift`。
- 角色：AI 生成结果的跨功能标准 Markdown 展示，当前由内容 AI Sheet 与提示词试运行共同使用。
- 边界：组件只消费累计 Markdown 快照和生成状态，不发起网络请求，不持有 Repository，也不决定业务结果是否可应用。
- 能力：流式 Markdown、标题/粗体/列表/表格/链接、跨区块文本选择、智能跟随、复制及表格导出。

## 快速接入

调用方用稳定的 `@State` 控制器承接滚动、Toast 与表格分享状态：

```swift
@State private var markdownController = AIMarkdownInteractionController()

AIMarkdownResultView(
    markdown: cumulativeMarkdown,
    isStreaming: generationPhase == .streaming,
    interactionController: markdownController
)
.onAppear {
    markdownController.configure(
        toastCenter: toastCenter,
        reducesMotion: reduceMotion
    )
}
```

开始新一轮生成前调用：

```swift
markdownController.resetForNewGeneration()
```

表格导出的系统分享 Sheet 仍由业务页面呈现；关闭页面时应丢弃尚未分享的临时文件。

## 参数说明

| 参数 | 说明 |
| --- | --- |
| `markdown` | 截至当前的完整累计 Markdown，不是单个增量片段。 |
| `isStreaming` | 是否仍在生成；用于流式渲染与智能跟随生命周期。 |
| `interactionController` | 页面持有的稳定交互 owner，负责滚动位置、复制反馈、链接策略和表格导出。 |

## 示例

对照结果要为每一侧持有独立控制器，避免滚动位置和导出会话串线：

```swift
AIMarkdownResultView(
    markdown: currentResult,
    isStreaming: currentIsStreaming,
    interactionController: currentController
)

AIMarkdownResultView(
    markdown: defaultResult,
    isStreaming: defaultIsStreaming,
    interactionController: defaultController
)
```

## 常见问题

### 为什么输入必须是累计快照？

`AIStreamingMarkdownSource` 会回放最新完整内容，使 Dynamic Type、条件视图切换或渲染器重订阅后仍能恢复当前结果。只传增量会导致重建后丢失前文。

### 为什么不使用系统 `Text` 直接显示？

AI 输出需要在生成过程中解析 Markdown，并保持表格、链接、选择与复制语义一致。普通 `Text` 无法提供这组交互合同。

### 什么时候不应使用？

HTML 正文使用 `RichText`；Markdown 源码编辑使用文本编辑器；普通静态短文本直接使用 `Text`。不要为了统一外观把非 AI 内容接入流式渲染器。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
