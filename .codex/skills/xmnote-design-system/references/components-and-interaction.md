# 组件与交互

本参考提供场景路由和误用边界，不维护完整公共组件清单。每次实现仍须实时查询：

```bash
python3 scripts/design-system/ds.py catalog --symbol <已知符号名子串>
python3 scripts/design-system/ds.py catalog
```

`--symbol` 只匹配 `symbols` 子串，不匹配中文用途。已知组件名时用过滤命令；未知时读取完整 catalog，再按语义筛选。

只有 catalog `status: canonical` 的条目可作为跨场景公共入口；`support` 只供其 owner 内部协作。文件存在、被生产代码使用、位于 `UIComponents` 或带 `XM` 前缀都不能替代登记。读取返回项的 `useWhen`、`avoidWhen`、`usageScope`、`stateCoverage`、依赖和 Preview 策略；本参考与 catalog 冲突时以 catalog 和真实 owner 为准。

## 目录与依赖方向

- 页面壳层位于 `xmnote/Views/<Feature>/`，ViewModel 位于 `xmnote/ViewModels/<Feature>/`。
- 页面私有子视图位于 `Views/<Feature>/Components`，业务 Sheet 位于 `Views/<Feature>/Sheets`。
- 跨模块稳定 UI 位于 `xmnote/UIComponents`，只依赖更底层设计能力和少量稳定展示值，不访问 Repository、ViewModel、数据库或网络客户端。
- `Utilities/DesignSystem` 不依赖业务页面或 Domain；Domain 不持有 SwiftUI/UIKit 的 Color、Font、Image 或 View 类型。
- SwiftUI 是默认组合层；UIKit 仅用于机器目录登记的系统桥接、媒体生命周期、富文本或命中测试等窄边界。
- 组件接收纯展示值、Binding 和动作；业务状态、异步编排、校验、保存与错误恢复仍由 feature owner 持有。

新 UI 没有 catalog 匹配时，默认先落到页面私有组合。不得先放入 `UIComponents` 再寻找第二个消费者。

遇到已存在但 catalog 未登记的 `UIComponents` 文件时进入隔离流程：

1. 标记为“未登记设计系统债务”，不是 canonical 或可复制范例。
2. 当前任务不新增消费者、不扩展 API、不把它包装成新的公共入口。
3. 若现有页面已经使用且本次不负责治理，保持其行为并在结论中报告，不顺手大范围替换。
4. 确需继续使用或治理时，单独核对两个独立生产场景、依赖方向、状态、Preview、测试和 catalog 合同；不满足准入则改为 feature 私有组合或已有 canonical 入口。
5. 不通过新增 baseline、扩大排除或仅补一个 catalog 名称掩盖语义和状态证据不足。

## 场景路由锚点

下表不是静态目录，只列出容易重复造轮子的稳定入口；使用前仍运行 catalog。

| 场景 | 查询/首选入口 | 不适用时 |
| --- | --- | --- |
| 卡片式配置页 | `XMSettingsPage`、`XMSettingsSection`、`XMSettingsGroup` | 普通业务列表、表单 Sheet 或内容页保留自身容器 |
| 单一开关/离散值设置行 | `XMSettingsToggleRow` / `XMSettingsValueMenuRow` | 双行说明、输入、多选、异步或业务卡保留私有组合 |
| 通用业务 Sheet | `XMSheetScaffold` | 系统选择器、中心决策弹窗或没有业务 Sheet 关系的页面不用套壳 |
| 中心确认、警告、决策、轻量输入 | `XMSystemAlert` | 页面内状态、Toast、菜单和业务 Sheet 分别使用自己的入口 |
| 不打断任务的短驻留消息 | `XMToast` | 成功可由界面状态表达、需要确认或风险决策时不用 Toast |
| 页面/Sheet/列表背景的空、无结果、失败 | `XMContentStateView` | 卡片内或保留内容时改用对应紧凑/行内入口 |
| 卡片/分区局部状态 | `XMCompactStateView` | 整页阻断或已有可信内容时不用 |
| 保留可信内容的刷新/分页/写入失败 | `XMInlineStatusBanner` | 内容完全不可用时进入完整 failure |
| 读取加载与阶段承载 | `LoadingGate`、`LoadingStateView`、`LoadPhaseHost` | 可确定进度和局部写入反馈按真实 owner 处理 |
| 顶部 action、特殊返回拦截 | `TopBarActionIcon` / `TopBarBackButton` | 普通 Sheet 关闭使用 scaffold；页面图标和系统自动入口不用 |
| 内容范围/显示模式的互斥选择 | `XMScopeSelector` | 导航 Tab、独立业务动作或多选条件不用 |
| 自定义列表/卡片选择标记 | `XMSelectionIndicator` | 系统 Toggle/Picker 能表达时优先系统控件 |
| 内容区常驻搜索 | `XMInlineSearchField` | 导航栏搜索优先 `.searchable`；全局路由搜索由其 owner 管理 |
| 纯展示领域标签 | `XMTagLabel` | 筛选、状态、评分、指标和可点击 Capsule 不用 |
| 书籍封面 | `XMBookCover` | 头像、任意比例图片或普通远程媒体不用 |
| 普通远程图片、附件、图库、只读富文本 | 分别查询 `XMRemoteImage`、附件、JX Gallery、RichText owner | 不用一个通用图片/富文本组件覆盖不同生命周期 |

## Settings

卡片式配置页组合语法：

```swift
XMSettingsPage {
    XMSettingsSection("分区标题") {
        XMSettingsGroup {
            // canonical 简单行，或页面私有业务组合
        }
    }
}
```

- `XMSettingsPage` 统一滚动、全轴回弹、页面背景、横向边距、底部空间和规则宽度最大内容宽度；页面不复制内部数值。
- `XMSettingsSection` 统一分区标题、内容线对齐和标题—内容亲密性。
- `XMSettingsGroup` 统一 grouped/singleItem 表层、内部留白、连续形态过渡和弱分割线。`singleItem` 只用于没有附属输入、提示或错误内容的唯一顶层设置行。
- `XMSettingsDivider` 只分隔同组设置，不作为普通列表通用 divider。
- `XMSettingsToggleRow` 只表达单一标题与开关；`XMSettingsValueMenuRow` 只表达离散当前值菜单。
- 双行说明、凭证编辑、自由输入、多选、异步状态、账号卡和领域卡片使用页面私有组合，但继续消费 `SettingsTypography`、Settings 布局和语义色。
- Dynamic Type 下允许行自然增高；不得为了保持整齐固定裁剪多行标题或值。
- 禁止给稳定行持续增加 icon、subtitle、error、loading、accessory 等可选参数形成万能行。

### 双行 Settings 私有行

双行说明、图标化入口和异步业务状态仍保持 feature 私有，但已有稳定的 Settings 组合语法：

- 使用 `XMSettingsPageLayout.detailRowMinHeight`（当前 64pt）作为最小高度，只消费 token，不复制当前数值；不要设置固定高度。单行 canonical 行当前 52pt 的内部高度不用于双行行型。
- 文本列使用 `VStack(alignment: .leading, spacing: Spacing.compact)`；标题为 `SettingsTypography.rowTitle + textPrimary`，从属说明为 `rowDescription + textSecondary`。说明默认允许纵向自然增长，不随意改用 `half/base` 或降成 `caption2`。
- `XMSettingsGroup` 持有组级横向留白；私有行不再重复一层相同 horizontal padding。需要自管行内垂直节奏时仍保留 group 表层 owner。
- 简短当前值或状态使用 `SettingsTypography.rowValue` 放在 trailing accessory。出现长说明、校验或可重试失败时贴近正文/字段，不把它压进 trailing 单行值。
- 没有前导 icon/media 时，`XMSettingsDivider` 保持组内内容宽度；存在前导槽位时，divider 前缘对齐标题正文列。私有 `Layout` 用真实 slot 宽度加行内 spacing 计算，不复制另一页面的 inset 数字。
- 带 trailing value、Toggle、icon 或处理状态时，必须在 Accessibility 字号和最长中文下渲染。现有私有行尚未形成统一的横向转纵向实现；发生挤压时优先 reflow，不用缩小关键文字。未渲染前标记“适配风险，需截图验证”。

配置 Sheet 不嵌套 `XMSettingsPage`。根使用 `XMSheetScaffold`，内部只组合 `XMSettingsSection/XMSettingsGroup` 和行；scaffold 是唯一 ScrollView owner，避免第二层滚动、重复背景和重复页面边距。

## 业务 Sheet

- `XMSheetScaffold` 持有标题栏、关闭或双侧操作、全轴回弹滚动区、可选固定内容顶栏/底栏及 scroll-edge 协同。
- 内容槽传入内容组合，不再传入完整 ScrollView；选择能满足任务的最简单 initializer，只有真正固定的控件才启用 top/bottom bar。
- 静态副标题使用 `subtitle`；动态或可交互副标题使用类型安全 `titleSubtitle` 槽位。标题—副标题亲密性由 scaffold 管理，页面不重写。
- 固定搜索/筛选属于 `contentTopBar`，提交或确认区属于 `bottomBar`；普通内容仍在主滚动闭包中。
- 槽位保留具体泛型 View，不使用 `AnyView` 消除差异。
- scaffold 不持有 Repository、保存策略、校验、选择状态或异步任务。
- 页面不得在 scaffold 内再造第二套标题栏、关闭按钮、回弹或底部模糊。
- 系统照片/文件选择器、日期控件、中心 Alert 或简单系统分享不强行套业务 Sheet。

### Sheet 提交位置

先判断数据何时生效，再选择唯一提交层级：

| 提交关系 | 入口 | 约束 |
| --- | --- | --- |
| Binding/行操作即时持久化，关闭不丢草稿 | 标准 close | 不添加“保存/完成”制造伪提交 |
| Sheet 持有独立草稿；提交是短、单一文字动作；操作旁不需持续显示进度或错误 | 成对 `leadingAction` 取消 + `trailingAction` 提交 | 两侧都使用原生 Button；不复制某个 feature 的私有 pill/字号作为公共样式 |
| 长列表/长表单中主操作必须常驻，需要全宽强调，或进度、禁用原因、失败必须与操作保持空间关系 | `bottomBar` | 错误在按钮上方，processing 在按钮/操作区内；内容尾部不再复制提交入口 |

同一 Sheet 只保留一个保存入口。标题栏不承载 spinner、长错误、双行文案或复杂状态；`XMSheetScaffold` 当前也不提供双侧标题动作与 bottomBar 同时提交的语法，不能另造重复层级。

### 校验、保存和输入适配

- 用户能通过某字段修正的错误贴在字段下方，允许换行；错误存在时禁用提交，重新编辑时清除已过期的提交错误。不要用 Toast 代替可在当前任务中修正的字段错误。
- 整体提交失败且字段本身合法时，贴近固定操作区；已有可信内容且可重试时使用 `XMInlineStatusBanner` 靠近来源区域。失败不 dismiss，保留草稿、选择和输入焦点恢复路径。
- 保存开始后立即提供可感知反馈，禁用重复提交以及会丢失草稿的关闭/交互收起；成功后用 dismiss 或内容变化表达，不额外发送成功 Toast。
- 若使用 bottomBar，按钮内 processing 与状态文案是当前最成熟模式；其他入口只固定“立即反馈、禁用重复触发、保留草稿”，不要强行复制同一种 spinner 位置。
- 当前生产代码没有两个独立的异步字段校验场景，因而没有通用 `isValidating` 视觉、debounce 时序或成功勾选规范。此类状态保留 feature 私有，过期响应、取消和保存编排由状态 owner 处理，不新增公共校验组件。
- 包含可换行文本、输入、校验或动态内容的 Sheet，在 Accessibility 字号下不得继续使用未经测量的固定 height detent；使用 `.large`，或由专用组件 owner 按 Dynamic Type 计算高度。固定数字只允许给内容封闭且经过字号矩阵验证的局部 owner。
- 输入型 Sheet 验证键盘出现、交互收起、提交前失焦、失败后继续编辑和 bottomBar 可达性；不要新增第二层 ScrollView 或用硬编码 keyboard padding 补偿。
- 标题/副标题是单行 chrome。长说明、错误和动态状态进入滚动内容或固定操作区；发现可能截断时先报告适配风险并截图验证。

## 导航、切换与顶部操作

- 当前 Tab 内继续深入：该 Tab 的 `NavigationStack`、route enum 与稳定 path。
- 必须覆盖 `TabView` 且返回时保留底层现场：根视图 item-driven full-screen cover；cover 内需要继续深入时使用独立 NavigationStack。
- 只补充当前页面的参数、选择、确认或短信息：Sheet、popover 或 Alert。
- 三者都不匹配时重新判断页面关系，不自造 overlay 导航和转场系统。

顶部规则：

- 特殊返回拦截使用 `TopBarBackButton`；没有拦截需求时优先保留系统返回，不要手写 `Button + chevron.left`。
- 普通业务 Sheet 使用 `XMSheetScaffold` 自带关闭入口。当前 `TopBarDismissButton` 含阅读计时专用可访问性文案，不能泛化为任意 modal dismiss。
- 需要保留系统返回手势并拦截脏状态退出时，查询 `navigationPopGuard`；无拦截需求不接入。
- `TopBarActionIcon` 只承载顶部普通 action glyph，本身不是 Button；调用方必须使用原生 Button 并提供正确可访问性标签。它不承担页面内图标或装饰。
- `TopBarActionPill` 只用于恰好两个同权重顶部 action；单一操作、不同权重或导航栏外胶囊不用。
- 系统 NavigationBar 已提供外观时，不再给按钮套 glass/material。
- 主 Tab 顶部标题/一级内容切换查询 `TopSwitcher`；内容区局部互斥筛选查询 `XMScopeSelector`，两者不能因都是“分段选择”互换。
- 切换后必须保留已激活页面状态与滚动现场时查询 `KeepAliveSwitcherHost`；稳定 ID 内容需要横向直操、分页吸附和生命周期回调时查询 `HorizontalPagingHost`。真正导航不伪装成切换器。

## Menu、搜索与选择

- 普通菜单项使用 `XMMenuLabel` 和 `xmMenuNeutralTint()`；顶部工具栏受根品牌 tint 污染时使用 `xmToolbarNeutralTint()`。
- 删除、警告等菜单项保留系统 destructive/warning 语义，不套中性普通操作样式。
- 导航栏原生搜索优先 `.searchable`；滚动内容内需要常驻搜索、清除、取消和键盘提交时使用 `XMInlineSearchField`。
- 最近关键词的展示、删除和清空查询搜索历史组件；不要把它混成搜索结果或标签筛选。
- 系统 Toggle、Picker、Menu 能直接表达状态时优先系统控件；只有自定义列表/卡片选择才使用 `XMSelectionIndicator`。
- 纯展示标签使用 `XMTagLabel`；只要可点击、可筛选、代表状态或指标，就回到对应交互/业务 owner。

## 普通按钮与输入控件

机器目录目前没有可泛化到所有业务的主按钮或通用表单字段组件；catalog 缺席时使用原生控件和页面私有组合，不得从未登记文件或某个 feature 的私有按钮反推公共规范。

按钮先按任务成本分层：

- 页面/Sheet 唯一的提交、创建或确认可以使用 `primaryActionFill + primaryActionForeground`；同一任务面内通常只保留一个同权主按钮。
- 取消、返回、筛选、排序、更多和辅助跳转保持系统/中性色，不因可点击就使用品牌填充。
- 删除与不可逆操作使用原生 destructive role 和 `feedbackError` 语义，不与品牌主按钮伪装成同一层级。
- 标签使用结果明确的动词；图标不能是唯一语义。按钮保持 `InteractionMetrics.minimumTouchTarget`，处理中文字宽度、Dynamic Type 和 loading 前后宽度稳定。
- 写入开始立即禁用来源；按钮内可以显示局部 spinner 和“保存中…”等状态，但业务 phase 不进入通用 ButtonStyle。失败后恢复可操作并保留上下文。
- 不为普通按钮自行增加玻璃、渐变、重阴影或胶囊；只有 catalog 返回的场景 owner 才能提供这些外观。

输入先保留系统行为，再添加业务边界：

- 普通文本输入使用 TextField/SecureField/TextEditor；键盘类型、content type、大小写、提交键和焦点由字段语义决定。
- 输入值使用主要正文层级与 `textPrimary`，placeholder 使用 `textHint`；字段 label、hint、计数和错误按 Settings/表单上下文选择对应 Typography，不在输入框内复制一套固定字号。
- 可修复错误紧邻字段，使用 `feedbackError` 加自然语言；不能只改变边框颜色。字符计数只有接近/超过限制时才升级反馈层级。
- 普通设置输入最小体量查询 `XMSettingsPageLayout.inputMinHeight`（当前 48pt）；实际点击区仍不得低于 44pt。多行 TextEditor 高度属于 feature `Layout`，必须验证键盘和 Dynamic Type，不进入全局 token。
- 不用自定义占位 Text 覆盖系统输入命中，不用 `onTapGesture` 模拟焦点，也不用硬编码键盘 offset。密码、粘贴、自动填充、清除和 VoiceOver value 保留系统语义。

## 状态与反馈决策

### 先判断内容是否仍可用

1. 数据尚未返回：placeholder 或 loading，不是 empty。
2. 数据源确认没有数据：`.empty`。
3. 搜索或筛选没有匹配：`.noResults`。
4. 无可用内容且读取失败：`.failure`。
5. 等待用户前置选择：`.instruction`。
6. 已有可信内容，仅刷新、分页或写入失败：保留内容并显示 `XMInlineStatusBanner`。

完整页面、Sheet 或列表背景使用 `XMContentStateView`；卡片和局部容器使用 `XMCompactStateView`。通用状态组件只承接展示角色、文字、图标和单一动作，不持有业务加载阶段、ViewModel 或恢复策略。

不要把 loading、success 或领域 phase 加入 `XMStateRole`；这些属于加载门闩、反馈结果或业务状态 owner。

`XMCompactStateView(style: .card)` 已经拥有卡片表层，不再嵌套 `CardContainer`。`XMInlineStatusBanner` 的外部位置和与内容的间距由调用方负责。

### 再判断反馈成本

- 需要确认、存在风险、需要用户决策或轻量输入：`XMSystemAlert`。生产路径不新增 SwiftUI `.alert` 作为中心弹窗。
- Alert 的 destructive role 只给真实破坏动作；item-driven 呈现只保留一个状态 owner，避免多个 Bool 竞争。
- 不需要决策且短暂说明即可：`XMToast`。错误 Toast 只适合不阻断后续任务的轻量失败。
- 成功已经由内容变化、导航、选择或按钮状态明确表达：不再发成功 Toast。
- 手动排序成功不提示；失败必须回滚或解释。搜索、筛选或非手动排序不可排序时前置阻断。
- Toast 采用 newest-wins，不把多条状态排队；processing 必须由后续状态替换或显式关闭。
- Toast host 只在 App 根挂载一次，业务页面只提交消息，不各自创建呈现层。

### 加载意图

- 读取主态使用 `LoadingGate + LoadingStateView` 或 `LoadPhaseHost`。当前 `readDefault` 延迟 150ms、显示后最短驻留 200ms，防止闪烁；实现时读取 owner，不在页面复制时序。
- `LoadingGate` 只管理视觉时间，不是网络状态 owner；页面在出现、业务阶段变化和取消/离场时同步它，离场时清理未完成的显隐任务。
- `LoadingStateView` 只是视觉，不脱离 gate/phase host 直接绑定请求状态。
- 写操作使用 `.write`/即时反馈并禁用重复触发入口；写入中的 spinner 可以属于按钮或局部 owner，不机械套整页读取加载。
- 可确定百分比、上传/导入、扫描和 AI 流式状态由领域流程持有，不强行改造成通用 loading。
- 裸 `ProgressView` 是 `DSR003` 观察项，不自动等同缺陷；先区分读取主态、写入局部反馈和可确定进度。

## 点击热区与控件语义

- 44pt 是默认有效点击区基线。主操作、导航、关闭、破坏性或不可逆操作、频繁/连续交互、独立图标按钮和表单控件必须达到 `InteractionMetrics.minimumTouchTarget`。
- 紧凑视觉可以小于 44pt，但交互轮廓不应改变可见 frame、背景、行高和相邻布局。
- SwiftUI 紧凑控件查询并使用 `xmMinimumHitTarget(anchor:)`；UIKit 紧凑按钮使用 `XMMinimumHitTargetButton`。不要自己再声明 44。
- 位于屏幕或容器边缘时选择 anchor，把扩展量导向真实可命中区域。
- anchor 和布局方向必须同时验证 RTL，不能只按左/右物理边推导。
- 系统控件已合规、相邻扩展区会重叠、祖先裁断超出 bounds，或透明命中会覆盖子控件时，不机械扩展。
- `.frame(minWidth:minHeight:)` 只用于可见容器本来就应达到该尺寸的场景，不是所有 44pt 问题的默认修复。

小于 44pt 的自然命中范围只允许给以展示为主的内联次级文字，并且同时满足：低频、非破坏性、不是完成主任务的必要入口。例外仍使用 Button/NavigationLink 等原生控件，在相邻代码说明业务角色、低频和非破坏性依据、为何不扩展，以及邻近控件不会歧义；“低频”单独不构成例外。

普通点击使用 Button、Toggle、NavigationLink 等原生语义；`onTapGesture` 只用于已登记的复杂手势边界，并提供 VoiceOver 替代。`policy.json` 中的 gesture exception 是精确声明例外，不可类推到相似页面。

## 滚动与边缘

- App 自有 SwiftUI `ScrollView/List/Form` 等必须继承全局 always-bounce，或由组件 owner 按有效轴显式使用 `.scrollBounceBehavior(.always)`；已继承时不机械重复 modifier，禁止 `.basedOnSize`。
- UIKit 按真实滚动轴设置 `alwaysBounceVertical/Horizontal = true`；不显式关闭有效轴向 bounces。
- 图片缩放画布、明确禁用滚动的静态骨架和第三方 Vendor 组件除外，不为满足列表规则破坏其物理。
- 系统导航边缘使用原生 scroll-edge effect，不用自定义 blur、gradient 或 material 遮罩模拟。
- 有固定顶栏/底栏且需要系统边缘协同时查询 `XMScrollEdgeChrome`；固定筛选栏或卡片内滚动视口需要非交互柔化时查询 `XMScrollEdgeWash`。Wash 不模拟系统导航栏，也不承载点击。
- 需要系统识别主滚动视图时，内容状态下的主滚动容器保持页面根内容的直接滚动主体；固定反馈优先通过系统安全区能力接入，避免额外容器隔断识别。

## 书籍、媒体与系统桥接

- 所有书籍封面使用 `XMBookCover`，由组件处理统一比例、裁切、占位、失败、尺寸模式和可选厚度边；阴影与业务叠放由场景 owner 决定。
- 父宽驱动网格使用 responsive，列表常用 fixedWidth，高度驱动布局使用 fixedHeight；只有有意裁切、堆叠或 mosaic 才使用 fixedSize。`.spine` 显式 opt-in，并由组件按尺寸降级。
- 父行已经完整朗读书籍身份时，把封面作为装饰隐藏；独立封面才提供有意义的可访问性标签。
- `XMRemoteImage` 用于普通跨模块远程静态/GIF 图片，不用于书封、JX Zoom 缩略图或本地资产。
- 附件上传条持有上传、删除、重试和排序生命周期；只读图库不复用上传组件。
- 需要全屏浏览与 Zoom 转场时使用机器目录登记的 JX Gallery 家族；普通单图不引入整套浏览器生命周期。
- JX gallery item 使用稳定业务 ID；可变或重排集合不能把数组 index 当图片身份。能够提供真实图片描述时，不只使用兜底“图片”。
- 只读 HTML、折叠预览、富文本编辑分别查询自己的 owner，不因都展示富文本而合并。
- 系统分享使用 item-driven 的 `XMActivityShareSheet`；导出生成逻辑留在业务 owner，不由分享桥接负责。

## 适配与可访问性执行

- 辅助功能 Dynamic Type 下优先纵向 reflow，不用 `minimumScaleFactor` 把关键文字压小。
- 与文本尺度相关的自定义几何使用 `@ScaledMetric` 或真实 typography 测量；44pt 命中语义仍保持。
- 单一只读语义的复合行可以 combine；包含独立操作的容器保持 contain，并让每个动作可单独聚焦。
- 自定义控件必须同时检查 label、value、traits、action 和焦点顺序，不是只补一个 accessibilityLabel。
- 必验默认字号、辅助功能字号、最长中文、RTL、VoiceOver 顺序与提示、禁用态、Reduce Motion 和相邻点击歧义。
- 代码中发现单行标题、固定尺寸或缩放因子时，只能先报告适配风险；是否真实截断仍需渲染证据。

## 公共组件准入

新增或扩展 `UIComponents` 前必须同时证明：

1. catalog 没有正确入口，且现有组件的 `avoidWhen` 确实命中。
2. 至少两个独立生产场景具有相同语义、状态边界和修复模式。
3. 接口能够限制错误使用，不依赖大量样式开关、业务枚举或可选槽位。
4. 依赖方向稳定，不反向持有业务状态或数据访问。
5. 状态覆盖、Preview 策略、目录登记和收口文档能够完整维护。

只复用一段布局代码、只服务一个工作流、需要大量参数才能覆盖差异，或视觉方案尚未经截图验证时，保留页面私有实现。扩展现有 Style 也必须证明是同一容器语义下的稳定视觉差异，不能用 Style 枚举隐藏多个不同组件。
