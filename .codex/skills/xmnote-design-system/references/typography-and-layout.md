# 排版、间距与布局

本参考把真实 token owner 中已经稳定的选择逻辑整理为执行协议。表内数值是当前视觉基线，不是可在页面复制的字面量；实现前仍须读取对应源码，源码与本参考不一致时以源码和生产消费者为准。

## 真实 owner

- 全局文本角色：`xmnote/Utilities/DesignSystem/AppTypography.swift`
- 动态字号桥接：`xmnote/Utilities/DesignSystem/SemanticTypography.swift`
- 跨页面阅读内容：`xmnote/Utilities/DesignSystem/SharedContentTypography.swift`
- 书架局部排版：`xmnote/Views/Book/BookshelfTypography.swift`
- 间距：`xmnote/Utilities/DesignSystem/Spacing.swift`
- 圆角与描边：`CornerRadius.swift`、`StrokeWidth.swift`
- 允许使用底层构造器的路径：`scripts/design-system/policy.json` 的 `DS001`、`DS002`、`DS004`

`component-catalog.json` 只确认 `UIComponents` 身份，不登记 `Utilities` 或 feature typography。查排版与间距时使用 `ds.py context`、真实 owner 和生产消费者；查 `TopSwitcher`、Settings 等组件时再使用 catalog。

## 文本先分类，再选 token

选择顺序固定为：已有 feature/component Typography → 已证明跨页复用的共享 Typography → `AppTypography` 成型角色。不得从期望字号反向挑 token，也不得为了局部观感在相邻档位间随意切换。

| 内容角色 | 默认入口 | 使用边界 |
| --- | --- | --- |
| 系统导航标题 | `navigationTitle` 与系统导航栏 | 不用自定义 `Text` 模拟系统导航标题 |
| 自定义焦点标题 | `largeTitle`、`title2`、`title3` 或已登记 feature token | 只用于真正的页面焦点、品牌焦点或高层指标，不用于普通卡片标题 |
| 卡片、列表、分区首要标题 | `headline` / `headlineSemibold` | 不承载长正文；只有层级确需增强时使用 semibold |
| 主要正文、标准控件标签 | `body` / `bodyMedium` | 普通强调优先调整结构和颜色，不随手加粗 |
| 次级值、列表副文本、紧凑说明 | `subheadline` 及已成型 weight 变体 | 不承担页面主要任务或长篇阅读正文 |
| 更紧凑的说明正文 | `callout` | 不把所有辅助文字都降到 footnote |
| 说明、校验、弱状态、次级动作 | `footnote` 及已成型 weight 变体 | 信息仍影响决策时优先 `textSecondary`，不要同时缩小并过度淡化 |
| 时间、来源、标签、密集元数据 | `caption` / `caption2` 及已成型变体 | `caption2` 不承载关键正文、主要操作或必须读懂的风险 |
| 代码式短值 | 先检查现有局部 owner；已有匹配场景才考虑 `monospacedFootnote` | 当前复用证据较弱，不作为全局默认排版角色 |

当前系统默认内容字号（Large）下，`AppTypography` 的名义层级如下；这些数值帮助比较层级，不是页面可复制的固定字号。实际缩放由系统 text style 与当前 Dynamic Type 决定：

| `AppTypography` 入口 | 当前名义基线 | 细分规则 |
| --- | ---: | --- |
| `largeTitle` | 34pt | 自定义最高焦点；系统导航大标题仍使用 `navigationTitle` |
| `title2` | 22pt | 页面内高层标题或重要指标，不作为普通分区标题 |
| `title3` / `title3Semibold` | 20pt | 紧凑焦点标题；只有真实层级需要时选择 semibold |
| `headline` / `headlineSemibold` | 17pt | 卡片、列表、分区首要标题；不替代正文 |
| `body` / `bodyMedium` | 17pt | 主要正文、标准控件；medium 是受控强调，不是默认加粗 |
| `callout` | 16pt | 比正文更紧凑但仍需连续阅读的说明 |
| `subheadline` 及 weight 变体 | 15pt | 次级值、副文本和紧凑说明 |
| `footnote` 及 weight 变体 | 13pt | 说明、校验、弱状态和次级动作 |
| `caption` 及 weight 变体 | 12pt | 时间、来源、标签和一般元数据 |
| `caption2` 及 weight 变体 | 11pt | 最密集元数据；不得承担关键说明或主要操作 |

同一名义字号也可能承担不同角色，例如 17pt headline 与 body。选择必须先看信息角色和系统 text style，不能只按点数互换。显式 `Medium/Semibold` 变体只改变已命名的字重；普通页面不在 token 后再追加 `.weight(...)`。

生产文本禁止直接新增 `.font(.system(size:))`、`UIFont.systemFont` 或 `UIFont.boldSystemFont`。SF Symbol 等 glyph 的视觉尺寸由图标 owner 管理，不按生产文本处理。

不要在页面层对成型 token 继续散落 `.weight(...)`。如果两个以上独立生产场景需要相同角色和字重，先检查已有成型变体；否则保留在当前 feature/component Typography owner，并证明后再晋升。

## 已定稿的专项层级

这些组合已经有明确 owner。使用时直接调用组合 token，不在页面重建相同字号、字重和行距。

| 场景 | 当前基线 | 决策规则 |
| --- | --- | --- |
| Settings 行标题 | `SettingsTypography.rowTitle`，17pt 语义层、medium | 设置项的主要名称 |
| Settings 当前值 | `rowValue`，15pt、regular | 右侧当前值或状态；视觉上低于行标题 |
| Settings 说明 | `rowDescription`，13pt、regular | 补充说明、校验与弱状态 |
| Settings 分区标题 | `sectionTitle`，13pt、semibold | 只表达配置分组，不模拟页面标题 |
| 书摘正文 | `ReadingContentTypography.body`，当前 16pt，行距 7pt | 阅读内容第一层级 |
| 书摘批注/想法 | `annotation`，当前 14pt，行距 5pt | 明确低于引用正文一层 |
| 阅读元数据 | `metadata`，当前 11pt | 时间、来源等辅助信息，前景优先 `textSecondary` |
| 阅读摘要指标 | `ReadingSummaryTypography` | 标题、数字、单位、副标题按已有角色组合，不单独放大某个页面 |
| 书架搜索 | `BookshelfTypography.searchField`，当前 15pt | 搜索输入、placeholder 与取消动作保持同源 |
| 书架网格标题/副标题 | `gridTitle/gridSubtitle`，当前 12/11pt | 长标题用已有截断、换行或跑马灯处理，不通过放大字号修复 |

书架顶部选中/未选中层级由 catalog 登记的 `TopSwitcher` 内部持有；页面不得直接消费或复制 `BookshelfTypography.topSelected/topUnselected`。如果后续 owner 发生变化，必须重新用 catalog、生产消费者和 Git 历史证明，而不是保留两套顶部排版入口。

### 书架网格专项

书籍卡片的稳定内部关系不是通用卡片规则：

- 书名通过 `BookshelfTitleText(style: .captionMedium)` 消费 `BookshelfTypography.gridTitle`，同时统一搜索高亮和尾部截断；standard/compact 当前一行，full 当前两行。页面不跳过它直接重建书名。
- 作者/主元数据使用 `BookshelfTypography.gridSubtitle` 与 `textSecondary`。渲染 token 与 UIKit 测量 token 不同源时先报告 owner 漂移，即使当前字号碰巧相同也不能视为安全。
- 封面到文字块使用 `Spacing.half`，书名到作者使用 `Spacing.tiny`。这是书架卡片内部已校准关系，不推广为其他卡片默认。
- 排序辅助行只有在业务确实返回值时出现，仍低于作者层级；任何固定 item-height 公式都必须把该条件行及其 `Spacing.tiny` 计入，不能靠追加一个常量高度掩盖漏算。

先区分三个真实 owner，禁止把“书架网格”概括成一套算法：

| 网格 | 当前布局性质 | 修改入口 |
| --- | --- | --- |
| 默认书架 book grid | UIKit compositional layout，绝对高度公式 | `BookshelfDefaultCollectionView` 与 `BookGridItemView` |
| 二级书单 book grid | UIKit compositional layout，绝对高度公式 | `BookshelfBookListCollectionView` / layout factory 与 `BookshelfBookListGridItemView` |
| 聚合分组 grid | estimated/self-sizing 路径与独立列数逻辑 | `BookshelfAggregateCollectionView` |

当前 2/3/4 等列数属于持久化产品偏好或局部能力范围，不是 Dynamic Type breakpoint。不得把某个设备宽度、字号类别或 Preview 列数晋升为全局“自动降列”阈值；先读取对应 owner 和用户显示设置。

`AppTypography.semantic/fixed/uiSemantic/uiFixed/brandDisplay/brandTrim` 是受控构造入口，不是页面自由调参 API。`fixed` 只固定默认 base size，仍按 `relativeTo` 响应 Dynamic Type；`minimumPointSize` 是 base clamp，不是全 App 的渲染下限。只有 `policy.json` 已登记的 feature/component Typography owner 可以继续使用；普通页面优先消费成型 token。需要新增 owner 时，先说明现有角色为何不匹配、Dynamic Type 基准、UIKit 同源测量需求和至少两个生产场景证据。

## 文本布局与测量

- 长正文同时明确行距、最大宽度、换行和截断策略；不要只选字号。
- `ReadingContentTypography` 的 7/5pt 是排版 owner 的行距，必须和对应字体成对使用；不要因为数值相近改写成 `Spacing`。
- 默认让 Dynamic Type 自然增高。辅助功能字号下，单行值、水平按钮组和固定行高必须重新检查；必要时取消 `lineLimit(1)` 或切换为纵向组合。
- 只有非辅助功能字号才可谨慎使用 `minimumScaleFactor`；不得用缩放代替合理换行。
- SwiftUI 渲染与 UIKit 测量必须来自同一 typography owner。例如网格书名的测量使用 `BookshelfTypography.uiGridTitle`，不得另造相似 `UIFont`。
- 品牌字体只进入已登记的品牌标题或数字焦点；中文正文、交互文案和长内容保持系统字体及 Dynamic Type。
- 判断“太大、太小、太挤、层级不清”需要截图或实际渲染；代码只能确认 token 与结构是否可疑。

### UIKit 与固定网格的测量合同

SwiftUI 文本嵌入 UIKit collection/list 或依赖绝对 cell 高度时，Typography 不只是一个渲染 token，而是“SwiftUI Font、同源 UIFont、可用宽度、行数/截断策略、测量缓存和布局刷新”的完整合同：

- 渲染和测量使用同一 feature Typography owner；发现一边使用 feature token、另一边使用近似 `AppTypography` 时，先标记 owner 漂移，不继续靠高度补偿。
- 测量使用与渲染一致的内容宽度、line limit、换行和截断模式；不得用单行测量支撑两行渲染，或忽略 accessory、内边距和列间距。
- content size category、trait collection、容器宽度、列数、line limit 或文本内容变化时，使相关测量缓存失效并刷新 collection layout；不要只更新可见文字而保留旧 item height。
- 绝对 item height 必须由同源测量和既有间距组成，不能裁掉 Dynamic Type 增长。需要硬上限时，说明它保护的业务几何并用渲染矩阵证明不会截断关键内容。
- 辅助功能字号下，先比较减少列数、允许标题/副标题增行和切换列表三种 feature 级方案。仓库尚无统一阈值时不得在 Skill 写死列数；用真实设备宽度、最长文案和字号矩阵确定，并且不静默改写用户持久化的显示偏好。
- `UIHostingConfiguration` 继承当前渲染 trait，不代表外层 UIKit 绝对高度公式自动同步；UIFont 构造、缓存 identity 和 layout invalidation 必须显式使用同一 content-size-category/trait。
- preferred content size category、effective content width、配置列数、标题模式和会改变可见文本行的条件都属于布局 identity；重建/失效布局时保留当前 viewport，避免字号或分屏变化造成跳位。
- 调整书架网格排版时至少验证：默认与二级两个 book-grid host、grid/list、紧凑/规则/分屏实际内容宽度、默认/较大/至少一个 Accessibility 字号、用户允许的列数、standard/full 标题、排序辅助行有/无、空/长作者、长中文与拉丁标题、搜索高亮、旋转/分屏和滚动复用。聚合网格按自己的 estimated owner 单独验证。
- 固定网格存在条件辅助行、trait 未进入测量或渲染/测量 Typography owner 不一致时，先阻断“追加高度常量”的修复；报告结构风险，补齐完整公式与 trait-aware 测量，再用截图决定 self-sizing、feature 级降列或 list。

## 间距四步选择

1. 先确认它表达的是留白，而不是线宽、点击区、图标尺寸、控件高度或底部操作预留。
2. 判断关系层级：行内亲密关系、同级内容块、容器内边距、页面与大分区。
3. 优先选择该层级默认档。
4. 默认档确实无法表达当前密度时，才使用补位档；不要从补位档开始试值。

### 当前间距基线

| Token | 值 | 默认用途 | 禁止误用 |
| --- | ---: | --- | --- |
| `compact` | 4 | 图标与短文本、非常紧密的成组关系 | 不作为卡片主内边距 |
| `half` | 6 | 主值与副标题、紧密纵向信息组 | 不用于页面大分区 |
| `cozy` | 8 | 图表标题到图表、紧凑同级内容 | 不用于需要明显断开的模块 |
| `base` | 12 | 常规内容块、按钮组、列表内部节奏 | 不代替页面安全边距 |
| `screenEdge` | 16 | 页面横向安全边距 | 不是所有组件的通用 padding |
| `contentEdge` | 18 | 普通卡片或内容容器内边距 | 不用于图标与文字 |
| `section` | 20 | 模块级强调分组 | 不用于行内关系 |
| `double` | 24 | 大段留白、强分区 | 不用于密集控件内部 |
| `hairline/tiny/micro` | 1/2/3 | 描边避让、视觉补偿、极小留白；`micro` 只在真实组件 owner 已定稿时表达极紧密关系 | 不作为卡片、列表或页面主间距 |
| `tight/comfortable` | 10/14 | 默认档之间确有证据的密度补位 | 不作为新页面的起始选择 |

`Spacing.none` 只表达明确的零间距。相同数字不代表相同语义：点击区使用 `InteractionMetrics`，描边使用 `StrokeWidth`，组件尺寸留在组件 `Layout/Metrics` owner。

### 常见组合

- 图标与短标签：先试 `compact`；图标和较长正文通常从 `half` 或组件既有 owner 开始。
- 标题与从属副标题：普通内容先试 `half`；Sheet 的系统静态副标题与动态标题槽分别由 [业务 Sheet](sheets.md) 和 scaffold owner 管理，页面不重写其间距。
- 同一语义块中的段落或控件：先试 `cozy` / `base`。
- 卡片内容到边缘：先试 `contentEdge`，简单紧凑卡片可以由其组件 owner 选择 `base`。
- 页面横向边距：使用 `screenEdge`，规则宽度下再由页面容器决定最大宽度。
- 相邻模块：从 `section` 开始；需要强分区时才使用 `double`。

页面确需不能由 `Spacing` 表达的布局量时，命名为业务语义清楚的私有 `Layout/Metrics` 常量，并说明它是内容尺寸、操作预留、算法阈值还是视觉校准；不要新增全局 token 收藏单页数字。

`DS002` 重点约束 `padding`、stack spacing 与 `lineSpacing` 的无语义字面量，不意味着所有 `frame`、绘图阈值和组件尺寸都必须进入 `Spacing`。明确的页面级组合常量可以保留在真实 owner。

## 圆角与边界

先判定角色，再选体量。所有 `RoundedRectangle` 保持 `.continuous`，除非真实系统组件或形状语义要求不同。

下表只负责不依赖外部容器关系的固定圆角。系统 Sheet 外轮廓、容器感知的同心复合面板及嵌套连续关系统一读取 [业务 Sheet](sheets.md)，不得从下表反推固定半径模拟系统容器。

| 角色 | Token 范围 | 典型场景 |
| --- | --- | --- |
| `inlay` | `inlayHairline` 2、`inlayTiny` 3、`inlaySmall` 4、`inlayMedium` 6 | 色块、热力格、书封、标签、徽章和嵌入式控件 |
| `block` | `blockSmall` 8、`blockMedium` 10、`blockLarge` 12 | 事件条、列表项、输入框、标准内容卡片 |
| `container` | `containerMedium` 16、`containerLarge` 18、`containerXL` 22 | 面板、弹层、突出容器和大型品牌展示 |

- `CornerRadius.none` 只用于明确关闭圆角的状态。
- Capsule 是内容与高度共同决定的真实形态，不用超大圆角数字模拟；Settings 单项形态交给 `XMSettingsGroup`。
- 组件已拥有内部圆角时，页面不覆盖。`XMBookCover`、Settings、图表格和状态卡各自由真实 owner 决定。
- 通用轻量轮廓使用 `StrokeWidth.hairline` 当前 0.5pt；不要把 `Spacing.hairline` 当描边宽度。
- 边框只解释边界，不应与阴影、嵌套表层和重色同时叠加来制造“完成度”。

## 布局验收

### 设置标签与从属说明

- 设置项是控件标签，优先复用 `SettingsTypography.rowTitle`，当前为 `bodyMedium`；页面标题、分区标题和主操作分别使用自身角色，不为统一点数把所有文本设为 headline。
- 微信读书伴随式面板经用户确认将三个设置标签改为 `AppTypography.body`（Regular），让主操作保持视觉强调；这是该面板的局部选择，不把全局设置标签改为 Regular，也不把此前 Medium 验证通过等同于字重已经最优。
- 从属说明使用 `SettingsTypography.rowDescription`，保留次级可读颜色；先判断它属于单项还是整个分区，再决定组合位置。单项说明不应仅因实现方便独立排到整行容器之外。
- 实际标题—说明距离不等于一个 spacing 值：最小行高、Toggle 高度、文本行框和额外 padding 都可能产生留白。先修分组与对齐，再调整已有令牌；不得仅减小外置 padding 或用负 offset 掩盖结构问题。
- 点击热区与文字亲密性分开处理。收紧文字不能缩小控件命中范围；多行文本旁的开关若需对齐标题，应以标题位置为依据，避免跟随整段文本中心下移。
- 普通双行 Settings 的默认组合继续按 [组件与交互](components-and-interaction.md) 使用 `Spacing.compact`。微信读书伴随式面板经局部视觉验证使用 `Spacing.half`，说明限定左列；这是场景选择，不是全局替换。当前源码见 `xmnote/Views/Personal/DataImport/WereadImportActionPanel.swift`。

- 亲密性必须反映语义：同组更近、跨组更远；不能仅因视觉整齐把不同重要度内容等距排列。
- 先解决对齐、留白、尺寸和信息顺序，再增加卡片或装饰层。
- 固定尺寸只留给封面比例、图表绘制、交互基线或已有组件 owner；文本容器和普通页面不得假设单一屏宽。
- 至少检查短文本、最长本地化文本、默认与辅助功能字号、320pt 紧凑宽度和规则宽度。没有渲染证据时，把密度结论标记为“视觉风险，需截图验证”。
