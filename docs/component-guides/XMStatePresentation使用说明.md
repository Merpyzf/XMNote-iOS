# XMStatePresentation 使用说明

## 组件定位

- 源码目录：`xmnote/UIComponents/Foundation/StatePresentation/`
- 角色：统一页面、Sheet、列表背景、卡片和局部容器中的空态、无搜索结果、说明态、失败态、Inline Banner 与加载视觉。
- 边界：组件族只负责展示，不拥有 Repository、ViewModel 或业务状态机。
- 平台基础：页面级状态由 `XMContentStateView` 统一包装系统 `ContentUnavailableView`。

## 快速接入

先根据容器和内容可用性选择组件：

| 场景 | 组件 |
| --- | --- |
| 页面、Sheet、列表背景没有主体内容 | `XMContentStateView` |
| 卡片、分区、局部内容区没有内容 | `XMCompactStateView` |
| 已有内容仍可用，只需固定提示失败或限制 | `XMInlineStatusBanner` |
| 读取主态或局部加载视觉 | `LoadingStateView` |

页面完整空态：

```swift
XMContentStateView(
    role: .empty,
    title: "暂无书籍",
    message: "添加书籍后会显示在这里。",
    systemImage: "books.vertical"
)
```

搜索无结果：

```swift
XMContentStateView(
    role: .noResults,
    title: "没有找到结果",
    message: "尝试更换关键词或清除筛选条件。"
)
```

已有内容刷新失败：

```swift
XMInlineStatusBanner(
    "部分内容暂时无法刷新，当前内容仍可继续浏览。",
    tone: .warning,
    action: XMStateAction("重试", systemImage: "arrow.clockwise") {
        retryRefresh()
    }
)
```

## 参数说明

### `XMStateRole`

| 角色 | 使用条件 | 默认图标 |
| --- | --- | --- |
| `.instruction` | 等待用户先选择或完成前置操作 | `info.circle` |
| `.empty` | 数据源读取完成且确实为空 | `tray` |
| `.noResults` | 搜索或筛选条件下没有匹配 | `magnifyingglass` |
| `.failure` | 没有可用内容且读取失败 | `exclamationmark.triangle` |

### `XMStateAction`

| 参数 | 说明 |
| --- | --- |
| `title` | 唯一主要动作标题。 |
| `systemImage` | 可选 SF Symbol。 |
| `isEnabled` | 动作是否可触发；异步重试期间应由业务状态关闭。 |
| `perform` | 同步触发闭包；异步任务和重复触发保护仍由页面 owner 负责。 |

### `XMContentStateView`

| 参数 | 说明 |
| --- | --- |
| `role` | 必填展示语义。 |
| `title` | 系统完整状态标题。 |
| `message` | 可选说明；空白字符串会被忽略。 |
| `systemImage` | 可选业务内容图标；不改变布局和颜色规范。 |
| `action` | 可选单一主要动作。 |

### `XMCompactStateView`

除完整状态的公共参数外，`style` 支持：

- `.centered`：居中局部内容区，不带卡片表层。
- `.card`：左对齐卡片状态，适合搜索失败和局部恢复提示。

组件不设置外层固定高度，调用方继续负责所在分区或列表背景的尺寸。

### `XMInlineStatusBanner`

| 参数 | 说明 |
| --- | --- |
| `message` | 必填提示文案。 |
| `tone` | `.neutral`、`.warning` 或 `.error`。 |
| `systemImage` | 可选 tone 图标覆盖。 |
| `action` | 可选单一恢复动作。 |

### 加载组件

- `LoadingStateView(style: .inline)`：轻量行内加载视觉。
- `LoadingStateView(style: .card)`：带卡片表层的加载视觉。
- `LoadingGate`：控制读加载的延迟显示和最短驻留。
- `LoadPhaseHost`：统一组合 placeholder、loading、content、empty 和 failure 阶段。

## 示例

### 示例 1：带重试的完整失败态

```swift
XMContentStateView(
    role: .failure,
    title: "暂时无法加载",
    message: errorMessage,
    action: XMStateAction(
        "重试",
        systemImage: "arrow.clockwise",
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
    title: "输入关键词搜索封面",
    message: "支持书名、作者或 ISBN。",
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
            title: "暂时无法加载",
            message: message,
            action: XMStateAction("重试") { reload() }
        )
    }
)
```

### 示例 4：UIKit 列表背景适配

UIKit 或 UICollectionView 适配器可以继续决定背景容器生命周期，但内部应使用公共状态组件：

```swift
let host = UIHostingController(
    rootView: XMContentStateView(
        role: isSearching ? .noResults : .empty,
        title: isSearching ? "没有匹配的标签" : "暂无标签"
    )
)
```

## 测试中心视觉验收

Debug 构建从“我的 → 测试中心 → 通用状态展示”进入全量目录。测试页与 SwiftUI Preview 共同使用 `StatePresentationCatalogView`，覆盖：

- `XMContentStateView` 四种角色。
- `XMCompactStateView` 四种角色与 `.centered`、`.card` 两种样式。
- `XMInlineStatusBanner` 三种 tone。
- `LoadingStateView` 的 `.inline`、`.card`。
- 长文案、业务图标覆盖、可用/禁用单一动作。
- `LoadPhaseHost` 五阶段交互切换。

测试页的外观、字号和 Reduce Motion 只覆盖预览区域。新增或扩展状态视觉时必须先在该目录补齐构造样例，不能单独维护另一套 Debug 示例。

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
2. 相同容器结构下存在稳定重复差异：扩展现有 `Style`，不要创建近义组件。
3. 两个独立生产场景已经证明相同语义、结构和修复模式：可以新增高抽象层级的公共状态组件。
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

不用。这些状态具有真实内容结构或领域工作流含义，可以保留业务实现；但其中出现通用空态、无结果或失败视觉时仍应组合公共组件。

### 6. 新增容器专属状态 View 如何通过校验？

先证明它承担必要的容器布局、UIKit 生命周期或领域结构。如果无法直接使用公共组件，在 `scripts/verify_state_presentations.sh` 的白名单中登记精确路径、类型和原因，并让通用视觉继续委托给状态组件族。

### 7. 设计师提出了现有组件无法表达的新状态样式，可以新增吗？

可以，但不能直接从单个页面抽取。先验证能否通过参数或既有 `Style` 表达；只有两个独立生产场景具备相同语义、结构和修复模式时才进入公共层，并按上文合同完成测试目录、治理文档和消费证据登记。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
