# XMScopeSelector 使用说明

## 组件定位
- 源码路径：`xmnote/UIComponents/Foundation/XMScopeSelector.swift`
- 角色：同一内容集合内的单选范围切换控件，用统一胶囊、滑动指示器、数量 badge 与跟手拖拽承载互斥选项。
- 边界：组件只负责范围选项展示、选中态写回、点击/拖拽交互、Dynamic Type 与无障碍语义；不负责搜索执行、数据筛选、数量统计或业务路由。
- 布局：2-5 项为等宽同屏；6 项及以上保持外层胶囊固定，只让内部内容横向滚动。
- 验证状态：已接入全局搜索顶部主范围；其他页面接入前仍需先在测试中心验证对应场景。

## 快速接入
```swift
enum SearchScope: Hashable {
    case book
    case note
    case relevant
    case review
}

@State private var scope: SearchScope = .book

let items = [
    XMScopeSelectorItem(id: SearchScope.book, title: "书籍", count: 18),
    XMScopeSelectorItem(id: SearchScope.note, title: "书摘", count: 42),
    XMScopeSelectorItem(id: SearchScope.relevant, title: "相关", count: 9),
    XMScopeSelectorItem(id: SearchScope.review, title: "书评", count: 5)
]

XMScopeSelector(
    items: items,
    selection: $scope,
    style: .content,
    countFormat: .plain,
    accessibilityLabel: "搜索范围"
)
```

## 参数说明
### `XMScopeSelector`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `items` | `[XMScopeSelectorItem<ID>]` | 必填 | 至少 2 个互斥选项。2-5 项等宽同屏，6 项及以上内部横向滚动。Debug 下少于 2 项会断言，生产下渲染为空。 |
| `selection` | `Binding<ID>` | 必填 | 当前选中项，必须存在于 `items`。点击或拖拽跨过分段时写回。 |
| `style` | `XMScopeSelectorVisualStyle` | `.content` | 视觉样式。`.content` 用于普通内容流，`.floatingGlass` 用于 iOS 26 功能浮层。 |
| `countFormat` | `XMScopeSelectorCountFormat` | `.plain` | 数量展示格式。`.plain` 保持原始数字，`.grouped` 使用本地化分组。 |
| `accessibilityLabel` | `String` | `"范围选择"` | 控件组的无障碍名称，例如“搜索范围”“筛选范围”。 |

### `XMScopeSelectorItem`
| 参数 | 类型 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `id` | `ID` | 必填 | 选项身份，必须可哈希并与外部 `selection` 同类型。 |
| `title` | `String` | 必填 | 视觉标题。长文案会按项目数量与 Dynamic Type 尾部截断或换行。 |
| `count` | `Int?` | `nil` | 可选数量 badge。视觉 badge 会隐藏重复朗读，无障碍读法仍包含数量。 |
| `accessibilityTitle` | `String?` | `nil` | 可选无障碍标题，用于视觉短标题不足以表达语义的场景。 |

### 视觉样式
| 样式 | 使用场景 | 说明 |
| --- | --- | --- |
| `.content` | 页面内容流、搜索结果顶部、列表筛选区 | 中性外壳、轻选中面、弱阴影；品牌绿只用于选中 count badge。 |
| `.floatingGlass` | iOS 26 功能浮层、悬浮工具区预览 | Liquid Glass 只作用于整体外壳底层，选中胶囊与文字保持中性可读面。 |

### 数量格式
| 格式 | 使用场景 | 说明 |
| --- | --- | --- |
| `.plain` | 搜索范围、计数需要原样呈现的业务场景 | 使用 `String(count)`，例如 `4203`。 |
| `.grouped` | 统计面板、强调可读性的汇总数字 | 使用本地化分组，例如中文环境下显示 `4,203`。 |

## 示例
### 示例 1：两项本地/在线范围
```swift
enum PickerScope: Hashable {
    case local
    case online
}

XMScopeSelector(
    items: [
        XMScopeSelectorItem(id: PickerScope.local, title: "本地"),
        XMScopeSelectorItem(id: PickerScope.online, title: "在线")
    ],
    selection: $scope,
    accessibilityLabel: "书籍来源"
)
```

### 示例 2：带数量的四项搜索范围
```swift
XMScopeSelector(
    items: [
        XMScopeSelectorItem(id: SearchScope.book, title: "书籍", count: 18),
        XMScopeSelectorItem(id: SearchScope.note, title: "书摘", count: 42),
        XMScopeSelectorItem(id: SearchScope.relevant, title: "相关", count: 9),
        XMScopeSelectorItem(id: SearchScope.review, title: "书评", count: 5)
    ],
    selection: $scope,
    style: .content,
    countFormat: .plain,
    accessibilityLabel: "搜索范围"
)
```

### 示例 3：六项以上内部横向滚动
```swift
XMScopeSelector(
    items: allScopes,
    selection: $scope,
    style: .content,
    countFormat: .plain,
    accessibilityLabel: "搜索范围"
)
```

### 示例 4：浮层玻璃样式
```swift
XMScopeSelector(
    items: items,
    selection: $scope,
    style: .floatingGlass,
    accessibilityLabel: "浮层范围"
)
```

## 常见问题
### 1) 为什么 6 项以上不继续压缩字号？
范围名称比数量 badge 更重要。6 项以上若强行同屏会牺牲可读性，所以控件保持外壳固定，内部选项横向滚动。2-5 项仍保留同屏等宽和跟手拖拽。

### 2) 为什么不用原生 `Picker(.segmented)`？
原生 segmented 是审美和交互标尺，但它不能可靠承载从属数量 badge、品牌轻强调和浮层玻璃外壳拆层。`XMScopeSelector` 保留原生相近的克制形态，同时补齐数量 metadata 与跟手拖拽。

### 3) 拖拽和点击如何共存？
每个分段仍是 `Button`，保证点击与 VoiceOver 语义；外层胶囊使用高优先级横向拖拽，拖拽跨过分段时连续写回 `selection`，松手后吸附到当前项。

6 项以上场景横向拖动语义切换为内部内容滚动，不再跨项跟手选择，避免选择手势和滚动手势冲突。

### 4) Reduce Motion 和 Dynamic Type 怎么处理？
Reduce Motion 开启时取消滑动吸附动画，保留即时状态变化和按压反馈。Dynamic Type 到 accessibility 尺寸时允许标题换行；拥挤时隐藏视觉 count badge，但无障碍读法仍保留数量。

### 5) 接入生产页面前要检查什么？
先确认场景语义是“同一内容集合内的互斥范围切换”，并准备稳定选项和外部 `selection` owner。接入前应在测试中心验证浅色、深色、浮层、大字号、Reduce Motion、6+ 内部滚动与 VoiceOver 读法，再替换真实页面里的临时按钮组。

[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
