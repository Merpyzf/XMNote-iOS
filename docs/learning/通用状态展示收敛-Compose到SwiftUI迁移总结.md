# 通用状态展示收敛 - Compose 到 SwiftUI 迁移总结

## 1. 先判断状态事实，再选择展示组件

页面状态不是一套固定的“图标 + 标题 + 描述 + 按钮”模板。Repository 与 ViewModel 负责判断数据事实，页面 owner 再把事实映射为展示语义；公共组件只统一视觉和交互，不持有业务状态机。

| 真实状态 | 公共表达 | 关键边界 |
| --- | --- | --- |
| 数据源确实为空 | `.empty` | 普通空态优先只显示事实标题 |
| query 或筛选后的派生结果为空 | `.noResults` | 不能与数据源为空混用 |
| 首次读取失败且没有可用内容 | `.failure` | 提供真实可执行的“重试” |
| 内容不存在或已失效 | `.instruction` 或业务明确的不可用状态 | 不提供无效重试，不伪装成普通空数据 |
| 已有内容仍可信，但刷新、分页或写入失败 | `XMInlineStatusBanner` | 保留内容，不切换为阻断页 |
| 读取、提交或确定进度 | `LoadingGate`、`LoadingStateView`、`LoadPhaseHost` 或业务 owner | 加载与进度不属于 `XMStateRole` |

这与 Compose 中由 Screen Composable 消费 `UiState`、再选择 Empty、Error 或 Content Composable 的职责相同。不要因为列表在某一帧暂时为空，就直接推断为真实空态。

## 2. 低权重排版比“完整结构”更重要

成熟的 C 端状态视觉首先要降低噪声，而不是补齐结构。本次采用以下稳定层级：

- `XMContentStateView` 与 `XMCompactStateView` 的标题统一使用 regular 字重和次要文本色；页面级与局部级通过容器、留白和布局关系区分，不通过粗体制造层级。
- 页面级与局部居中状态的图标使用 32pt regular；compact card 使用 18pt；Inline Banner 使用 16pt。
- 普通 `.empty` 不显示图标。只有搜索、失败、前置条件或确有业务辨识价值时才显示 SF Symbol。
- `.failure` 图标使用错误语义色；搜索、说明和内容失效使用中性色，避免把所有不可用状态都渲染成警报。
- 描述只补充用户无法从标题得知的原因或下一步；没有新增信息时直接省略。

这套规则避免了同一状态因为“页面级/局部级”“有无图标”“有无动作”而回落到不同字号、不同字重或系统默认大标题。

## 3. 状态动作不是页面主按钮

状态内动作承担恢复或修正，不应和页面主任务竞争视觉焦点：

- 状态动作使用纯文字、regular 字重和系统 borderless 交互，并消费独立的 `stateActionForeground` 保证浅色、深色和高对比模式下的小字号可读性；不把品牌填充色直接当作文字色，也不叠加填充色、描边胶囊、阴影或玻璃背景。
- 点击热区通过 `xmMinimumHitTarget` 或 `XMMinimumHitTargetButton` 扩展到至少 44pt，但不改变文字的可见 frame 和布局占位。
- “新增”“提交”“确认”等页面唯一主操作应由工具栏或页面操作区承载；已有可见入口时，空态不重复同一按钮。
- 状态动作只保留真实动词，例如“重试”“清除筛选”“显示全部”“去验证”。文字已经表达清楚时，不重复添加箭头图标。
- iOS 26 Liquid Glass 属于导航、工具栏和浮动功能层。空状态正文是内容层，不直接使用 `.glassEffect`、`.glass` 或 `.glassProminent`。

Compose 对应做法是使用 `TextButton` 表达轻量恢复动作，并通过 `Modifier.minimumInteractiveComponentSize()` 保证触控面积；页面级主要操作继续由 `TopAppBar`、FAB 或固定操作区拥有。

## 4. 可信内容决定错误反馈层级

错误视觉的首要判断不是选什么红色，而是页面是否还有可信内容：

- 首次读取失败：没有主体内容，使用页面级或局部 `.failure`，标题简短并提供“重试”。
- 内容失效：明确表达“不存在或已删除”，使用中性图标，不提供无法生效的重试。
- 刷新、分页或写入失败：保留已有内容，通过 Banner 提示简短结果；需要时提供单一恢复动作。
- 删除失败：保留详情并显示结果提示，不能绕过原删除确认直接在 Banner 中重试。
- 面向用户的文案不透传数据库、服务器、连接栈或 `localizedDescription` 等实现细节。

这比 Compose 中简单用 Snackbar 覆盖所有异常更精确：只有短驻留结果才使用 Toast；需要固定在内容上下文中并可恢复的错误使用 Inline Banner。

## 5. 强业务状态必须保留业务 owner

公共状态角色只覆盖相同语义和相同恢复模式。下列状态虽然也包含“空、失败或加载”，但不能为了统一而抹平业务生命周期：

- OCR 相机权限、受限、设备不可用和识别失败依赖深色取景器、相册回退与权限恢复路径，由 OCR 页面拥有。
- AI 连接、流式输出、空结果、部分结果失败和应用失败需要保留已生成内容及专属恢复入口，由 AI Sheet 拥有；其中已有内容后的失败可组合 `XMInlineStatusBanner`。
- 附件上传中、成功、失败和重试属于单个附件生命周期，由 `XMAttachmentUploadStrip` 在缩略图上下文中表达。
- 微信读书分批导入包含每批确定进度、成功、失败和行点击语义，由批次行拥有，不提升为页面通用角色。
- 书籍工作台状态位于共享头部、Tab 与底部搜索工具栏之间，其居中位置由 Collection 视口 owner 计算；公共状态组件不拥有固定高度或手工偏移。

测试中心可以直接复用这些生产展示单元和固定 fixture，但不能把它们移动到公共 `StatePresentation` 目录，也不能复制一套 Demo 专用视觉。

## 6. 文案要表达事实，不填充版面

状态文案遵循以下约束：

- 标题优先控制在 4–12 个汉字，直接描述事实，例如“暂无书籍”“没有匹配的章节”“暂时无法加载书评”。
- 短标题和短描述不加句号。
- 搜索框仍可见时，不重复关键词或补充“换个关键词试试”。
- 描述只在需要解释不可见原因或当前界面之外的下一步时出现，并且最多一句。
- 删除“添加后会显示在这里”“记录会出现在这里”“当前暂无相关内容”“轻松”“开启旅程”“尽情探索”等模板化文案。
- 按钮不用“知道更多”“立即体验”等模糊词，只写触发后确实发生的动作。

减少文案不是删除信息，而是让标题、说明和动作各自只承担一个职责。

## 7. Compose 与 SwiftUI 的实现对照

| Compose 常见实现 | SwiftUI 对应实现 | 迁移判断 |
| --- | --- | --- |
| Screen 根据 `UiState` 选择内容 | 页面 owner 根据业务 phase 选择状态组件 | 状态事实不能下沉到视觉组件 |
| `Text` 表达普通空态 | `XMContentStateView(role: .empty)` | 安静空态不需要完整模板 |
| 搜索派生结果复用 Empty | `.noResults` | 无结果不等于数据源为空 |
| `TextButton` + 最小交互尺寸 | borderless action + `xmMinimumHitTarget` | 视觉克制与触控可用性可以同时满足 |
| Snackbar 覆盖所有错误 | `XMInlineStatusBanner` / `XMToast` | 根据内容可信度和驻留需求选择 |
| 业务 Composable 保留局部进度 | OCR、AI、附件、导入的 feature owner | 领域生命周期不并入通用角色 |

### 7.1 Compose

```kotlin
@Composable
fun BookState(
    state: BookUiState,
    onRetry: () -> Unit
) {
    when (state) {
        BookUiState.Empty -> Text(
            text = "暂无书籍",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        BookUiState.NoResults -> QuietState(
            icon = Icons.Default.Search,
            title = "没有匹配的书籍"
        )

        BookUiState.Failed -> QuietState(
            icon = Icons.Default.ErrorOutline,
            title = "暂时无法加载书籍",
            action = {
                TextButton(
                    onClick = onRetry,
                    modifier = Modifier.minimumInteractiveComponentSize()
                ) {
                    Text("重试")
                }
            }
        )

        is BookUiState.Content -> BookList(state.books)
    }
}
```

### 7.2 SwiftUI

```swift
@ViewBuilder
private var content: some View {
    switch phase {
    case .loading:
        if loadingGate.isVisible {
            LoadingStateView("正在加载书籍")
        }

    case .empty:
        XMContentStateView(
            role: .empty,
            title: "暂无书籍"
        )

    case .noResults:
        XMContentStateView(
            role: .noResults,
            title: "没有匹配的书籍"
        )

    case .failure:
        XMContentStateView(
            role: .failure,
            title: "暂时无法加载书籍",
            action: XMStateAction("重试") {
                Task { await reload() }
            }
        )

    case .content(let books):
        BookList(books: books)
    }
}
```

示例只表达状态选择。实际页面仍需由真实数据流更新 `LoadingGate`，并在已有内容的刷新失败时继续渲染列表和 Banner。

## 8. 测试中心是生产状态验收入口

状态展示页必须使用真实生产组件和固定内存数据，集中呈现“生产模块｜触发条件｜层级｜实际组件”，而不是展示理想化 Demo。

验收至少覆盖：

- 安静页面空态、安静局部空态、可操作状态、搜索无结果、错误与内容失效。
- 保留内容后的 warning/error Banner、读取加载和完整 `LoadPhase`。
- OCR、AI、附件上传与批次导入的业务专用状态。
- 浅色、深色、320pt、规则宽度、Accessibility 3、Increase Contrast、Reduce Transparency、Reduce Motion、RTL 和 VoiceOver 阅读顺序。
- 文字动作的禁用与按压状态、至少 44pt 命中区，以及页面入口与状态动作不重复。

## 9. 迁移结论

- 先确认真实 owner、数据事实和恢复路径，再决定状态角色与组件层级。
- 公共状态组件统一字体、颜色、图标几何、动作和无障碍，不统一业务生命周期。
- 精致感来自信息减法、稳定层级和真实操作，不来自额外卡片、胶囊、玻璃或模板文案。
- 测试中心复用生产实现并标明业务来源，才能成为后续设计校准和回归检查的可信入口。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
