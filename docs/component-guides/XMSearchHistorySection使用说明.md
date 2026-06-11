# XMSearchHistorySection 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMSearchHistorySection.swift`
- 角色：跨搜索场景复用的最近搜索词区块，统一承载标题、展开/收起、编辑态、单条删除、清空入口、空态策略与流式 chip 布局。
- 边界：组件只负责搜索历史的展示与交互事件分发，不直接读写 Repository，不持有搜索 query，不负责中心确认弹窗的挂载位置。
- 视觉原则：chip 的视觉胶囊维持约 32pt 高度，触控区维持 44pt；编辑态右侧删除区以操作槽展开/收起表达，而不是条件插入淡入视图。
- 验证状态：已接入全局搜索页、书籍搜索页与 Debug `SearchHistoryTestView` 场景矩阵。

## 快速接入
```swift
@State private var isHistoryExpanded = false
@State private var isHistoryEditing = false

XMSearchHistorySection(
    queries: recentQueries,
    isExpanded: $isHistoryExpanded,
    isEditing: $isHistoryEditing,
    title: "最近搜索",
    emptyPresentation: .hidden,
    onSelect: { query in
        submit(query)
    },
    onRemove: { query in
        removeRecentQuery(query)
    },
    onClearAll: {
        isClearHistoryConfirmationPresented = true
    }
)
```

清空全部属于破坏性操作，生产页必须先弹出确认。`onClearAll` 只应请求确认，不应直接清空数据；确认按钮里再调用仓储或 ViewModel 的清空方法。

## 参数说明
### `XMSearchHistorySection`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `queries` | `[String]` | 必填 | 最近搜索词，建议由页面 ViewModel 从 Repository 读取后提供。组件按传入顺序渲染。 |
| `isExpanded` | `Binding<Bool>` | 必填 | 展开/收起状态。内容不足两行时组件会自动回落到收起态。 |
| `isEditing` | `Binding<Bool>` | `.constant(false)` | 编辑态状态。编辑态禁用 chip 选中，显示删除操作槽与清空/完成按钮。 |
| `style` | `XMSearchHistoryStyle` | `.content` | 视觉样式。`.content` 用于普通页面内容流，`.glass` 用于 iOS 26 浮层或实验场景。 |
| `title` | `String` | `"最近搜索"` | 区块标题。 |
| `emptyPresentation` | `XMSearchHistoryEmptyPresentation` | `.hidden` | 空态策略。生产搜索页通常隐藏；Debug 或独立页可显示文案空态。 |
| `expandsWhenEditing` | `Bool` | `true` | 进入编辑态是否自动展开所有历史。全局搜索和书籍搜索保持默认即可。 |
| `onSelect` | `(String) -> Void` | 必填 | 浏览态点击 chip 的回调。编辑态不会触发。 |
| `onRemove` | `(String) -> Void` | 必填 | 编辑态单条删除回调，不走确认弹窗。 |
| `onClearAll` | `() -> Void` | 必填 | 清空全部入口回调，只负责请求确认。 |

### `XMSearchHistoryEmptyPresentation`
| 值 | 使用场景 | 说明 |
| --- | --- | --- |
| `.hidden` | 搜索页主流程 | 无历史时不渲染区块，避免空页面出现低价值提示。 |
| `.message(title:subtitle:)` | Debug、独立管理页 | 显示图标、标题与可选说明，方便验证空态。 |

### `XMSearchHistoryStyle`
| 值 | 使用场景 | 说明 |
| --- | --- | --- |
| `.content` | 全局搜索、书籍搜索 | 中性内容面 chip，适合页面流。 |
| `.glass` | Debug 或 iOS 26 浮层验证 | chip 使用 Liquid Glass 表达，接入生产前必须验证可读性。 |

## 交互约束
- 编辑态删除按钮不是额外插入的尾随视图，而是 chip 内部保留稳定结构后展开右侧操作槽。
- 删除图标进入时允许轻微位移、缩放和少量透明度辅助，但动效主体必须是槽位宽度和图标位置变化。
- `isEditing` 不应交给父级大范围动画统一驱动；chip 自身使用局部 `.smooth`，Reduce Motion 下退化为短时 `easeOut`。
- 行距按视觉胶囊节奏设计，不按透明 44pt 命中区观感计算。
- 清空全部确认弹窗必须挂在能稳定覆盖当前搜索上下文的 owner 上，确认前不得修改 `queries`、`isEditing` 或 `isExpanded`。

## 示例
### 示例 1：全局搜索页本地确认
```swift
XMSearchHistorySection(
    queries: viewModel.recentQueries,
    isExpanded: $isHistoryExpanded,
    isEditing: $isHistoryEditing,
    title: "最近搜索",
    emptyPresentation: .hidden,
    onSelect: selectHistorySuggestion,
    onRemove: viewModel.removeRecentQuery,
    onClearAll: requestHistoryClearConfirmation
)
```

全局搜索使用系统 `.searchable`，请求确认前需要先释放键盘焦点；确认弹窗出现前不退出编辑态。

### 示例 2：书籍搜索页使用系统弹窗
```swift
.xmSystemAlert(
    isPresented: $isClearHistoryConfirmationPresented,
    descriptor: XMSystemAlertDescriptor(
        title: "清空搜索历史？",
        message: "这会移除全部最近搜索词，不影响你的本地内容。",
        actions: [
            XMSystemAlertAction(title: "取消", role: .cancel) { },
            XMSystemAlertAction(title: "清空", role: .destructive) {
                viewModel.clearRecentQueries()
                resetRecentQueryManagementState()
            }
        ]
    )
)
```

页面壳层能稳定承载 `XMSystemAlert` 时优先使用 `.xmSystemAlert`；不要在 `XMSearchHistorySection` 内部直接弹窗。

### 示例 3：Debug 场景显示空态
```swift
XMSearchHistorySection(
    queries: sampleQueries,
    isExpanded: $isExpanded,
    isEditing: $isEditing,
    style: .glass,
    emptyPresentation: .message(
        title: "暂无搜索历史",
        subtitle: "切换样本后验证空态布局"
    ),
    onSelect: logSelect,
    onRemove: removeSample,
    onClearAll: showClearConfirmation
)
```

## 常见问题
### 1. 为什么清空全部不能直接在 `onClearAll` 里执行？
清空是破坏性写操作。组件不知道当前页面是否处在系统搜索宿主、sheet、cover 或键盘焦点竞争中，所以只能把意图交给页面 owner。页面 owner 先稳定上下文，再展示确认；确认前底层历史区必须保持原样。

### 2. 为什么编辑态自动展开？
编辑是管理任务，用户需要看到完整候选集合。默认 `expandsWhenEditing = true` 会隐藏“更多/收起”切换，避免编辑态下同时出现两个管理层级。

### 3. 为什么删除按钮热区不是 44pt 宽？
单个图标视觉上不应占据 44pt 横向槽位，否则短词 chip 会显得松散。组件通过 32pt 图标热区、44pt chip 高度和 `contentShape` 保障可点性，同时保留紧凑阅读节奏。

### 4. Reduce Motion 下会怎样？
Reduce Motion 开启后取消明显位移和缩放，只保留短时透明度/状态变化，确保用户仍能识别编辑态进入、退出和删除按钮可用状态。

### 5. 接入新页面前要检查什么？
先确认最近搜索词的 owner 是页面 ViewModel 或 Repository，而不是组件内部状态；再确认清空确认挂载点不会和键盘、sheet、cover 或根级搜索宿主同帧竞争。最后在 Debug `SearchHistoryTestView` 复测 `shortNoise`、`mixed`、`longKeyword` 和 `fullCapacity` 场景。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
