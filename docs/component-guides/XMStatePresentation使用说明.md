# XMStatePresentation 使用说明

## 组件定位

- 状态源码目录：`xmnote/UIComponents/Feedback/StatePresentation/`
- 加载源码：`xmnote/UIComponents/Feedback/LoadingStateView.swift` 与 `xmnote/UIComponents/Feedback/Loading/LoadingFeedbackKit.swift`
- 角色：统一页面、Sheet、列表背景、卡片和局部容器中的空态、无搜索结果、说明态、失败态、Inline Banner 与加载视觉。
- 边界：组件族只负责展示，不拥有 Repository、ViewModel 或业务状态机。
- 平台基础：页面级状态由 `XMContentStateView` 统一包装系统 `ContentUnavailableView`，但标题、图标、说明和动作均使用项目自己的低权重语义，避免回落到系统默认粗标题。
- 材质边界：状态正文属于内容层，不使用 Liquid Glass。玻璃只由导航栏、工具栏或浮动功能层的真实 owner 提供。

## 快速接入

先根据容器和内容可用性选择组件：

| 场景 | 组件 |
| --- | --- |
| 页面、Sheet、列表背景没有主体内容 | `XMContentStateView` |
| 卡片、分区、局部内容区没有内容 | `XMCompactStateView` |
| 已有内容仍可用，只需固定提示失败或限制 | `XMInlineStatusBanner` |
| 读取主态或局部加载视觉 | `LoadingGate + LoadingStateView` 或 `LoadPhaseHost` |
| OCR、AI 流式输出、附件上传、批次导入等领域阶段 | 保留业务 owner，不扩充 `XMStateRole` |

安静页面空态只陈述事实：

```swift
XMContentStateView(
    role: .empty,
    title: "暂无书籍"
)
```

搜索完成但没有匹配内容：

```swift
XMContentStateView(
    role: .noResults,
    title: "没有匹配的书籍"
)
```

已有内容刷新失败：

```swift
XMInlineStatusBanner(
    "阅读记录暂未更新",
    tone: .warning,
    action: XMStateAction("重试") {
        retryRefresh()
    }
)
```

## 视觉与文案基线

- `.empty` 默认不显示图标。只有真实前置条件或当前状态内确有下一步时，才显式提供业务图标。
- `.empty`、`.noResults`、`.instruction` 和 `.failure` 的标题统一使用 `StatePresentationTypography.title`，当前为 `AppTypography.body` Regular 与 `textSecondary`。页面级和局部级不通过字号或字重制造层级差异。
- 页面/局部居中图标基准为 32pt，卡片图标为 18pt，Banner 图标为 16pt；三者分别由 `StatePresentationMetrics` 持有并随对应 Dynamic Type 语义缩放。
- 页面与局部状态动作使用 `AppTypography.subheadline` Regular 的纯文字 `.borderless` Button；Banner 动作使用 `AppTypography.footnote` Regular。三者统一消费 `stateActionForeground`，不直接把品牌填充色或错误色用作小字号动作前景；状态内不使用 bordered、prominent、胶囊背景或重复箭头图标。
- 动作通过 `xmMinimumHitTarget(anchor:)` 扩展至少 44pt 的非视觉命中区，不在标签上增加可见高度、背景或额外留白。
- Banner 始终使用中性弱表层和中性正文；`.warning`、`.error` 只通过 16pt 图标的语义色区分，不把整块背景染成警告色或错误色。
- 标题只说明事实，优先控制在 4–12 个汉字。描述仅补充用户看不见的原因或必要下一步，最多一句；短标题和短描述不加句号。
- 搜索框仍可见时不重复关键词，也不追加“换个关键词再试”。页面已经有新增入口时，状态内不复制第二个新增按钮。
- 禁止“添加后会显示在这里”“记录会出现在这里”“当前暂无”“开启旅程”“轻松”“尽情探索”等模板文案，也不向用户暴露数据库、服务器连接等实现细节。

## 参数说明

### `XMStateRole`

| 角色 | 使用条件 | 默认呈现 |
| --- | --- | --- |
| `.instruction` | 等待用户先选择或完成前置操作 | `info.circle` |
| `.empty` | 数据源读取完成且确实为空 | 安静空态，无图标 |
| `.noResults` | 搜索或筛选条件下没有匹配 | `magnifyingglass` |
| `.failure` | 没有可用内容且读取失败 | `exclamationmark.triangle`，使用 `feedbackError` |

内容不存在或已删除不是普通空数据，也不提供无效重试。使用 `.instruction` 并显式传入 `questionmark.circle`；文案直接写“……不存在或已删除”。

### `XMStateAction`

| 参数 | 说明 |
| --- | --- |
| `title` | 唯一动作标题，使用可独立表达结果的真实动词。 |
| `systemImage` | 兼容字段；当前生产状态动作禁止传入，统一使用纯文字。 |
| `isEnabled` | 动作是否可触发；异步重试期间应由业务状态关闭。 |
| `perform` | 同步触发闭包；异步任务和重复触发保护仍由页面 owner 负责。 |

### `XMContentStateView`

| 参数 | 说明 |
| --- | --- |
| `role` | 必填展示语义。 |
| `title` | 必填事实标题；四种角色均使用同一 Regular 排版。 |
| `message` | 可选必要说明；空白字符串会被忽略，不用于填充版面。 |
| `systemImage` | 可选业务图标；`.empty` 未传时保持无图标，其余角色使用默认语义图标。 |
| `action` | 可选单一真实动作；页面已有相同入口时传 `nil`。 |

### `XMCompactStateView`

除完整状态的公共参数外，`style` 支持：

- `.centered`：居中局部内容区，不带卡片表层。
- `.card`：左对齐卡片状态，适合搜索来源、前置条件和局部恢复提示；组件已拥有卡片表层，外部不得再包 `CardContainer`。

组件不设置外层固定高度，调用方继续负责所在分区或列表背景的尺寸。辅助功能字号下，带图标卡片从横向自动转为纵向；标题字重保持不变。

### `XMInlineStatusBanner`

| 参数 | 说明 |
| --- | --- |
| `message` | 必填提示文案。 |
| `tone` | `.neutral`、`.warning` 或 `.error`。 |
| `systemImage` | 可选 tone 图标覆盖；图标是唯一语义着色区域。 |
| `action` | 可选单一恢复动作；没有安全直接动作时保持 `nil`。 |

### 加载组件

- `LoadingStateView(style: .inline)`：中性轻量行内加载视觉，可不传文案。
- `LoadingStateView(style: .card)`：带卡片表层的中性加载视觉，适合目录写入等局部 owner。
- `LoadingGate`：控制读加载的延迟显示和最短驻留。
- `LoadPhaseHost`：统一组合 placeholder、loading、content、empty 和 failure 阶段。

## 示例

### 示例 1：带重试的完整失败态

```swift
XMContentStateView(
    role: .failure,
    title: "暂时无法加载书评",
    action: XMStateAction(
        "重试",
        isEnabled: !viewModel.isLoading
    ) {
        Task { await viewModel.reload() }
    }
)
```

### 示例 2：卡片内说明态

```swift
XMCompactStateView(
    role: .instruction,
    title: "需要完成验证",
    message: "完成后会继续搜索",
    systemImage: "checkmark.shield",
    action: XMStateAction("去验证") {
        presentVerification()
    },
    style: .card
)
```

### 示例 3：用 `LoadPhaseHost` 映射页面阶段

```swift
LoadPhaseHost(
    phase: phase,
    content: { contentList },
    placeholder: { Color.clear },
    loading: { LoadingStateView("正在加载…") },
    empty: { message in
        XMContentStateView(role: .empty, title: message)
    },
    failure: { message in
        XMContentStateView(
            role: .failure,
            title: message,
            action: XMStateAction("重试") { reload() }
        )
    }
)
```

### 示例 4：UIKit 列表背景适配

UIKit 或 UICollectionView 适配器可以继续决定背景容器生命周期，但内部应使用公共状态组件：

```swift
let host = UIHostingController(
    rootView: XMCompactStateView(
        role: isSearching ? .noResults : .empty,
        title: isSearching ? "没有匹配的目录" : "暂无目录"
    )
)
```

## 测试中心视觉验收

Debug 构建从“我的 → 测试中心 → 状态展示”进入统一验收入口。测试页不按 API 参数排列，而按真实生产语义分组：

- 页面状态：安静空态、真实引导动作、搜索无结果、筛选修正、内容失效和首次读取失败。
- 局部状态：书籍工作台局部空态、局部搜索、局部失败、BookSearch 前置验证和选书器下一步。
- 保留内容状态：阅读日历、书架、书摘列表和书评详情在内容仍可信时的 warning/error Banner。
- 加载阶段：热力图静默加载、目录写入反馈和 `LoadPhaseHost` 的 placeholder/loading/content/empty/failure。
- 业务专用状态：直接复用 OCR、AI、附件上传和微信读书批次导入的生产展示 owner，不复制 Demo UI，也不反向扩充公共角色。

`StatePresentationCatalogView` 只持有公共状态场景；`StatePresentationTestView` 在 Debug 层组合业务专用目录，避免 `UIComponents` 反向依赖 Feature。页面状态直接渲染在 `surfacePage`，局部状态只保留生产组件自身的真实容器。

测试页提供系统/浅色/深色、标准/特大/Accessibility 3、当前/320pt/规则宽度和 Reduce Motion 控制。页面状态样例使用固定 220pt 最小视口，使 Dynamic Type 只改变状态正文排版，不放大样例基线；目录标题和元数据固定为标准字号，避免验收说明干扰组件比较。

新增或扩展状态视觉时，必须补充来自生产路径的固定场景数据，并写明“生产模块｜触发条件｜层级｜实际组件”。禁止为测试中心复制组件、虚构欢迎页或保留旧版视觉 Demo。

## 生产消费证据

下表既记录当前公共视觉的复用事实，也作为后续新组件“双生产场景”准入格式。两个路径必须是不同生产 Swift 文件，Debug、Preview 和同文件重复构造不计入。

| 公共状态视觉 | 生产消费路径一 | 生产消费路径二 |
| --- | --- | --- |
| `XMContentStateView` | `xmnote/Views/Search/GlobalSearchView.swift` | `xmnote/Views/Note/NoteExcerptListView.swift` |
| `XMCompactStateView` | `xmnote/Views/Book/BookSearchView.swift` | `xmnote/Views/Reading/Timeline/ReadingTimelineView.swift` |
| `XMInlineStatusBanner` | `xmnote/Views/Reading/ReadingDashboardView.swift` | `xmnote/Views/Reading/ReadCalendar/ReadCalendarContentView.swift` |
| `LoadingStateView` | `xmnote/Views/Book/BookSearchView.swift` | `xmnote/Views/Content/ContentViewerView.swift` |

## 现有组件不贴合新 UI 时怎么办？

按以下顺序判断：

1. 只差文案、业务图标或业务状态映射：配置现有组件。
2. 两个独立生产场景已经证明同一容器存在相同语义、结构和修复模式：优先扩展现有 `Style`，不要创建近义组件。
3. 现有组件的职责边界确实不适用，且两个独立生产场景仍证明相同语义和结构：才可以新增高抽象层级的公共状态组件。
4. 单一工作流、领域结构或特殊容器生命周期：保留页面私有实现。

新公共组件必须位于 `StatePresentation/`，使用 `XM…StateView` 或 `XM…StatusBanner` 通用命名，只依赖设计令牌和展示语义，不得依赖业务模型、Repository、ViewModel 或网络状态。适用时复用 `XMStateRole`、`XMStateAction`，并同步测试目录、术语表、UI 组件文档清单、组件指南及两个真实生产消费路径。

## 常见问题

### 1. 为什么不能在页面里直接写 `ContentUnavailableView`？

系统组件只解决单点排版，不会自动统一项目角色、图标、动作样式和业务映射。统一入口能避免相同语义再次散落，并允许项目整体调整规范。

### 2. `.empty` 和 `.noResults` 怎么区分？

`.empty` 表示数据源已经确认没有内容；`.noResults` 表示当前搜索或筛选条件没有匹配。请求尚未返回时两者都不能使用。

### 3. 刷新失败应该显示完整失败页吗？

如果已有可信内容，不应该。保留内容并使用 `XMInlineStatusBanner`；只有没有任何可用主体内容时才使用完整 `.failure`。

### 4. 可以新增第二个动作吗？

通用状态每次最多一个主要动作。若用户需要多项选择或确认，说明场景已经超出状态展示边界，应使用页面内容、Menu、Sheet 或 `XMSystemAlert`。

### 5. 业务骨架、导入进度和 AI 流式状态要迁移吗？

不用。这些状态具有真实内容结构或领域工作流含义，应继续由业务 owner 持有。测试中心可以直接构造固定展示数据复用这些 owner，但不能把 Debug 组合提升为公共角色。

### 6. 新增容器专属状态 View 如何通过校验？

先证明它承担必要的容器布局、UIKit 生命周期或领域结构。如果无法直接使用公共组件，在 `scripts/verify_state_presentations.sh` 的白名单中登记精确路径、类型和原因，并让通用视觉继续委托给状态组件族。

### 7. 设计师提出了现有组件无法表达的新状态样式，可以新增吗？

可以，但不能直接从单个页面抽取。先验证能否通过参数或既有 `Style` 表达；只有两个独立生产场景具备相同语义、结构和修复模式时才进入公共层，并按上文合同完成测试目录、治理文档和消费证据登记。

### 8. 为什么“重试”等状态动作没有胶囊背景？

状态正文不是页面主操作区。纯文字 borderless 动作已经通过品牌色、位置和至少 44pt 的隐形命中区表达可点击性；再叠加同色胶囊会放大错误权重并与页面真正的创建、提交或确认动作竞争。

### 9. 为什么错误标题不加粗？

错误由语义图标和事实文案共同表达，不需要依靠粗体制造紧迫感。页面和局部状态统一使用 `AppTypography.body` Regular，避免搜索、空态、失效和失败在切换时发生视觉跳级。

### 10. 普通空态什么时候可以显示图标？

只有图标能说明当前前置条件、业务对象或真实下一步时才显式传入，例如当日阅读的日历状态。书架、目录和已有顶部新增入口的普通空态只显示一句事实标题。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
