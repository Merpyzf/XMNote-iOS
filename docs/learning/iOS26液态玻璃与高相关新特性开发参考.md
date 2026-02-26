# iOS26 液态玻璃与高相关新特性开发参考（XMNote）

## 1. 背景与适用范围

本参考用于 XMNote（Android -> iOS 迁移项目）的 iOS 26 开发落地，目标是：

- 业务意图与 Android 端保持一致。
- UI 与交互采用 iOS 原生表达，遵循 HIG 与系统新能力。
- 为 Android Compose 开发者提供可直接迁移的思维对照与示例。

本文件只覆盖与 XMNote 高相关的新能力，不做 iOS 26 全量特性百科。

## 2. 液态玻璃（Liquid Glass）落地原则

### 2.1 适用场景（优先）

- 顶部 App Bar 的操作按钮（如筛选、设置、排序）。
- 需要“浮层感”但不破坏内容阅读连续性的轻量交互控件。
- 首页顶部关键操作入口（统一视觉语言）。

### 2.2 不适用场景（避免）

- 大面积滥用导致信息层级混乱。
- 文字密集区或高对比业务内容上叠加过强玻璃效果，影响可读性。
- 与品牌主视觉冲突的重复装饰性玻璃层。

### 2.3 项目内统一策略

- 顶部右侧操作按钮使用液态玻璃按钮风格，尺寸保持紧凑（以可点击性为前提）。
- TopSwitcher 保持当前分段切换视觉，不强制改为液态玻璃。
- 阴影、边缘高光保持克制，优先沉浸感与层级清晰度。

## 3. SwiftUI iOS26 高相关交互模式

### 3.1 顶部区域（App Top）

- 顶部操作元素优先系统样式，避免自绘拟物特效。
- 顶部渐变背景在首页四个页面保持一致尺寸与节奏，保证切页连续性。

### 3.2 搜索入口交互

- 点击底部“搜索”Tab：先呈现底部搜索输入入口。
- 用户聚焦并输入后：再进入完整搜索页面/结果上下文。
- 避免“一点击即全屏跳转”造成认知负担，符合 iOS 26 新交互趋势。

## 4. Foundation Models（与 XMNote 的结合方式）

### 4.1 建议能力

- 书摘摘要、标签建议、复盘提问建议。
- 仅在用户触发时执行，避免后台不透明推理。

### 4.2 边界与降级

- 结果必须可追溯、可编辑、可撤销。
- 模型能力不可用时，回退到本地规则（关键词提取/历史标签推荐）。
- 任何 AI 输出不得直接覆盖用户原文。

## 5. App Intents（可暴露能力建议）

- 新建笔记、快速搜索书籍、打开最近阅读条目。
- 参数命名与业务术语统一（bookId、noteId、tagId）。
- Intent 结果页面必须可回到应用主导航上下文。

## 6. Call Translation / Declared Age Range（适配结论）

### 6.1 Call Translation

- XMNote 当前非通话类应用，默认不接入。
- 若后续加入语音访谈/朗读通话场景，再评估该能力。

### 6.2 Declared Age Range API

- 若未来引入未成年人模式或内容分级，需要评估并接入。
- 在未引入年龄分层业务前，仅做合规预研，不做过度实现。

## 7. XMNote 模块落地清单

- 首页（Reading/Book/Note/Personal）：
  - 顶部渐变背景尺寸一致。
  - 顶部右侧操作按钮统一液态玻璃视觉语言（保持紧凑与克制）。
- 搜索：
  - Tab 首次触发展示底部搜索入口，输入后进入完整搜索态。
- 个人中心：
  - 设置入口视觉层级与首页一致，避免风格漂移。
- AI 相关（后续）：
  - 优先 Foundation Models 的“建议型”能力，保留人工确认环节。

## 8. Android Compose -> SwiftUI 学习示例

### 8.1 思维映射

- Compose `TopAppBar + IconButton` -> SwiftUI `toolbar` / 顶部操作区按钮。
- Compose 状态驱动重组 -> SwiftUI `@State`/`@Observable` 状态驱动刷新。
- Compose `Modifier` 视觉叠加 -> SwiftUI `buttonStyle` + `overlay` + `background` 组合。

### 8.2 示例 1：顶部液态玻璃按钮（SwiftUI）

```swift
Button {
    // action
} label: {
    Image(systemName: "gearshape")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 34)
}
.buttonStyle(.glass)
```

### 8.3 示例 2：搜索“先入口后页面”触发（伪代码）

```swift
@State private var showsSearchSheet = false
@State private var keyword = ""

func onSearchTabTapped() {
    showsSearchSheet = true
}

func onSearchSubmit() {
    guard !keyword.isEmpty else { return }
    // push/search route
}
```

## 9. 实施检查清单（开发自检）

- 是否先对齐 Android 业务意图，再做 iOS 原生表达？
- 液态玻璃是否只用于关键操作层，未造成视觉噪音？
- 顶部区域在四个首页子页面是否保持一致节奏与尺寸？
- 异步交互是否有即时反馈（加载态/禁用态/错误提示）？
- 新能力是否具备降级方案与用户可控性？

## 10. Apple 官方文档索引

- Adopting Liquid Glass  
  https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Adopting Liquid Glass - App top  
  https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass#app-top
- Applying liquid glass to custom views  
  https://developer.apple.com/documentation/SwiftUI/Applying-liquid-glass-to-custom-views
- `GlassEffectContainer`  
  https://developer.apple.com/documentation/swiftui/glasseffectcontainer
- iOS 26 What's New  
  https://developer.apple.com/ios/whats-new/
- Foundation Models  
  https://developer.apple.com/documentation/foundationmodels
- App Intents  
  https://developer.apple.com/app-intents/
- Call Translation  
  https://developer.apple.com/documentation/calltranslation
- Declared Age Range API  
  https://developer.apple.com/documentation/declaredagerangeapi

